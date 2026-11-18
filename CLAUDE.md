# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

EasyQ is a macOS full-disk file search application inspired by Windows "Everything". It indexes the entire user home directory and provides instant filename search. The project is written in Swift with SwiftUI.

## Build & Run

- Open `EasyQ.xcodeproj` in Xcode
- Build target **EasyQ** (the main app) — this automatically builds and embeds EasyQAgent as a login item
- Deployment target: macOS 13.5 (target-level); project-level deployment target is 15.7
- Swift version: 5.0
- Single external dependency: SQLite.swift 0.16.0 (via Swift Package Manager, used by both targets)
- No test targets exist
- Bundle IDs: `icu.helltab.com.EasyQ` (app), `icu.helltab.com.EasyQ.agent` (agent)
- Code signing: Manual, identity `-` (ad-hoc)

## Architecture: Two-Process Design

The app runs as two separate processes that communicate via `DistributedNotificationCenter` (three named notifications form a bidirectional channel):

| Notification name | Sender → Receiver | Purpose |
|---|---|---|
| `com.easyq.agent.forceScan` | GUI → Agent | `userInfo["targetPath"]` for single-folder refresh, or `userInfo["rebuild"] = true` for full rebuild |
| `com.easyq.agent.scanProgress` | Agent → GUI | `userInfo` carries `currentPath`, `pendingTasks`, `scannedCount` for progress UI |
| `com.easyq.agent.scanComplete` | Agent → GUI | Signals all tasks drained; GUI refreshes views |

### EasyQ (Main App — `EasyQ/`)
- SwiftUI app with `NavigationSplitView` layout, `@main` in `EasyQApp.swift`
- Registers and launches EasyQAgent as a login item via `SMAppService.loginItem(identifier:)`; also checks if already running via `NSWorkspace.runningApplications` and launches the embedded bundle directly if needed
- Reads the shared SQLite database directly (read-only, with `PRAGMA read_uncommitted = 1` around every read)
- Search precedence: regex mode → FTS5 `MATCH` → `LIKE` fallback. Limited to 500 results. Sort by mtime / name / size
- Multi-keyword AND search (space-separated). Each keyword is CJK-normalized before querying FTS5
- Three detail modes: `.search` (query results), `.workspace` (pinned files), `.view` (rule-based virtual folder)
- Global hotkey `Cmd+Shift+Option+Space` (Carbon `RegisterEventHotKey`, signature `0x4551` = "EQ") activates the window
- Spacebar triggers `QuickLookHelper` (QLPreviewPanel) when search field is not focused
- Commands menus: `IndexMenuCommands` (强制刷新 / 重建索引) and `ViewMenuCommands` (重建所有视图), wired via `@FocusedValue` keys
- `ContentView.swift` is the main view and the single largest file — all UI state, context menus, sheets, and notification receivers live there

### EasyQAgent (Background Agent — `EasyQAgent/`)
- Login item agent (`LSUIElement = YES`, no dock icon). Entry point is top-level code in `main.swift` (no `@main` struct is used at runtime — `EasyQAgentApp.swift` exists but `applicationDidFinishLaunching` only logs)
- Requires Full Disk Access — checks by reading `~/Library/Safari/Bookmarks.plist`; if missing, opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`
- Core engine in `hellfs/` subdirectory:
  - **FSScanner**: Low-level directory scanner using `getattrlistbulk` syscall (64MB buffer). Requests `ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_OBJTAG | ATTR_CMN_MODTIME | ATTR_FILE_TOTALSIZE`. Uses `homeDepth` (set in `DynamicDirTaskManager.initTask`) to gate recursion for soft-skip dirs (only recurse 1 level beyond home depth). Skips symlinks, sockets, FIFOs, char/block devices. Skips dot-prefixed names. Tolerates 3 consecutive `getattrlistbulk` failures before giving up on a directory
  - **FileSyncManager**: Real-time change monitoring via `FSEvents` with 10-second debounce. Uses `Set<String>` dirty-path pool with `DispatchWorkItem` cancellation. Excludes `~/Library`, `~/.Trash`, `~/Downloads/.DS_Store` via `FSEventStreamSetExclusionPaths`
  - **DynamicDirTaskManager**: Orchestrator using `AsyncStream<(String, Int)>` as a task queue — the `Int` is `taskEpoch`, bumped on `rebuildAll()` so stale enqueued tasks are skipped (but still decrement `pendingTasks`). Implements `ScannerDelegate`. On launch: if `hasFiles()` is false → full scan; else if `isFTSEmpty()` → rebuild FTS only
  - **IgnoreSet**: Tiered filtering — hard-skip (node_modules, .git, Library, .Trash, DerivedData, etc., never recurse but the entry itself is still recorded), soft-skip (dist, build, target, vendor, Pods, etc., recurse 1 level only), dot-prefixed names always skipped. Loaded from `~/Library/Application Support/EasyQ/ignoreRules.json` (falls back to `defaultHardSkip` / `defaultSoftSkip` sets)
  - **Protocols**: `ScannerDelegate` protocol — `scannerDidFindFolder`, `scannerDidBatchFiles`, `scannerDidFinishProcessing`, `syncUpdate`, `syncDelete`
  - **cacheFS.swift**: Experimental/prototype scanner, superseded by `FSScanner.swift` — not called from `main.swift`
  - **AppMonitor.swift**: Launches EasyQ when Apple Music opens — experimental/unused

### Shared Database
- SQLite at `~/Library/Application Support/EasyQ/easyqfiles.db`
- Schema (`EasyQAgent/hellfs/db/ddl.sql` is a reference; actual DDL runs from `FileDatabase.createTableAndIndices()` in the agent):
  - `files` table: `id`, `parent`, `name`, `size`, `mtime`, `is_dir`
  - `UNIQUE(parent, name)` constraint, indices on `parent`, `name`, `mtime`
  - FTS5 virtual table `files_fts` (`name` column, external content mode: `content=files, content_rowid=id`)
- Agent writes with transactions; GUI reads concurrently via `PRAGMA read_uncommitted = 1`
- Agent also sets `PRAGMA mmap_size = 1073741824` and `PRAGMA cache_size = -2000` for performance (GUI side does not)
- GUI registers a custom SQLite function `regexp(pattern, value)` (using `NSRegularExpression`) so `WHERE name REGEXP ?` works in regex search mode
- **Self-heal**: Agent's `saveFilesInternal` retries once on "malformed" errors by calling `resetDatabase()` (removes db + `-shm` + `-wal`, reopens, recreates tables) then re-saving
- **FTS5 integrity**: Agent's `isFTSEmpty()` checks `files_fts_idx` row count; GUI's `isFTSHealthy()` checks `ftsCount >= fileCount / 2`. Both can trigger `rebuildFTS()` — agent version uses `DELETE FROM files_fts` + re-insert; GUI version uses `DROP TABLE` + recreate
- Every `saveFiles` / `upsert` / `delete` on the agent side keeps `files_fts` in sync per-row via `ftsSync(_:)`

### CJK Normalization (critical for Chinese search)
`normalizeCJK(_:)` is defined identically in both `EasyQ/DBManager.swift` and `EasyQAgent/hellfs/DBManager.swift`. It inserts spaces around every CJK Unicode scalar (ranges `4E00–9FFF`, `3400–4DBF`, `20000–2A6DF`, `F900–FAFF`) so that FTS5's `unicode61` tokenizer splits Chinese characters into individual tokens. Both index-time (agent) and query-time (GUI) must apply the same normalization, otherwise MATCH queries on Chinese names return nothing.

### Data Flow
```
FSScanner (getattrlistbulk) → ScannerDelegate callbacks → DynamicDirTaskManager (AsyncStream queue) → SQLite (files + files_fts per-row sync)
FileSyncManager (FSEvents) → 10s debounce → FileMetadata(path:) → SQLite (upsert/delete + FTS5 sync)
GUI ← SQLite (FTS5 MATCH query, read_uncommitted)
GUI ⇄ Agent via DistributedNotificationCenter (forceScan / scanProgress / scanComplete)
```

## Key Implementation Details

- **FileMetadata is defined separately in both targets**:
  - GUI version (`EasyQ/DBManager.swift`): `Identifiable` (`id = "\(parent)/\(name)"`), `Transferable` (drag to other apps), formatted display properties (`modificationDate` in `Asia/Shanghai`, `sizeString` via `ByteCountFormatter`). `SortOption` enum lives here
  - Agent version (`EasyQAgent/hellfs/DBManager.swift`): has `init()` and `init?(path:)` for reading file attributes from disk (used by `FileSyncManager.performSync`); no `Identifiable`/`Transferable`
- **`getDatabaseURL(name:)` and `DatabaseError` are duplicated across both targets** — shared code is not factored out
- **Agent logging** goes to `/tmp/easyq/EasyQAgent.log` via a global `log()` function in `main.swift` (also written to `stderr`). No logging on the GUI side (uses `print`)
- **FSScanner's `AttributeReader`** handles binary buffer parsing with manual alignment (`align(_:to:)` helper, `@inline(__always)`) for the `getattrlistbulk` return format
- **ViewManager** stores user-defined views in `~/Library/Application Support/EasyQ/views.json` and materializes them as directories of symbolic links under `views/<view name>/`. Same-name files in a view get `_<parentName>_<counter>` suffix
- **WorkspaceManager** stores pinned files in `workspace.json` (only `parent` + `name` persisted; other fields zeroed on load)
- **SearchHistoryManager** uses `UserDefaults` key `EasyQ_SearchHistory`, max 20 entries
- **IgnoreRulesManager** (GUI) and `IgnoreSet` (agent) share the `ignoreRules.json` schema (`hardSkip` + `softSkip` string arrays) but the GUI's `default` list omits `"easyQ"` (present only in agent's `defaultHardSkip`)

## Code Conventions

- Comments are primarily in Chinese (Mandarin)
- No formal linting or formatting configuration
- `ContentView.swift` is monolithic (~700 lines) — UI state, actions, context menus, sheets, and notification receivers all live in `FileSearchView`
- Path manipulation uses raw string concatenation (`parent + "/" + name`) throughout, with a `cleanedPath()` extension on `String` for trimming
