import SwiftUI
import Combine

extension String {
  func cleanedPath() -> String {
    return self.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
  }
}

private enum DetailMode: String, CaseIterable {
  case search = "搜索结果"
  case workspace = "工作区"
  case view = "视图"
  case space = "空间"
}

// MARK: - FocusedValue keys

struct FocusedIndexCountKey: FocusedValueKey { typealias Value = Int }
struct FocusedSelectFolderKey: FocusedValueKey { typealias Value = () -> Void }
struct FocusedRebuildKey: FocusedValueKey { typealias Value = () -> Void }
struct FocusedRebuildViewsKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
  var indexCount: Int? {
    get { self[FocusedIndexCountKey.self] }
    set { self[FocusedIndexCountKey.self] = newValue }
  }
  var selectFolder: (() -> Void)? {
    get { self[FocusedSelectFolderKey.self] }
    set { self[FocusedSelectFolderKey.self] = newValue }
  }
  var rebuildIndex: (() -> Void)? {
    get { self[FocusedRebuildKey.self] }
    set { self[FocusedRebuildKey.self] = newValue }
  }
  var rebuildViews: (() -> Void)? {
    get { self[FocusedRebuildViewsKey.self] }
    set { self[FocusedRebuildViewsKey.self] = newValue }
  }
}

// MARK: - Agent 暂存层增量缓存
// Agent 推送的未落库变更（含墓碑），搜索时与 SQLite 结果合并，实现零延迟可查
final class PendingChangeCache: ObservableObject {
  struct Entry {
    var file: FileMetadata
    var deleted: Bool
  }
  @Published private(set) var entries: [String: Entry] = [:]

  func apply(updates: [[String: Any]], deletes: [[String: Any]]) {
    for dict in updates {
      guard let parent = dict["parent"] as? String,
            let name = dict["name"] as? String else { continue }
      entries["\(parent)/\(name)"] = Entry(
        file: FileMetadata(
          parent: parent, name: name,
          size: dict["size"] as? Int64 ?? 0,
          mtime: dict["mtime"] as? Int64 ?? 0,
          isDir: dict["isDir"] as? Bool ?? false
        ),
        deleted: false
      )
    }
    for dict in deletes {
      guard let parent = dict["parent"] as? String,
            let name = dict["name"] as? String else { continue }
      entries["\(parent)/\(name)"] = Entry(
        file: FileMetadata(parent: parent, name: name, size: 0, mtime: 0, isDir: false),
        deleted: true
      )
    }
    // 容量保护：极端事件洪水时只保留更新项的一半（删除墓碑丢弃，库兜底）
    if entries.count > 100_000 {
      let keep = Array(entries.filter { !$0.value.deleted }.prefix(50_000))
      entries = Dictionary(uniqueKeysWithValues: keep.map { (key: $0.key, value: $0.value) })
    }
  }

  /// 清除已落库的条目（Agent 防抖周期落库后，本应发空推送；保险起见搜索时也可过期）
  func removeAll() { entries.removeAll() }

  /// 把暂存增量合并进 SQL 结果：墓碑剔除、新增/更新覆盖（按 id 去重，库结果优先低）
  func merged(with base: [FileMetadata]) -> [FileMetadata] {
    guard !entries.isEmpty else { return base }
    var result: [FileMetadata] = []
    var seen = Set<String>()
    // 暂存层更新项：放在最前（最新变更优先可见）
    for entry in entries.values where !entry.deleted {
      if !seen.insert(entry.file.id).inserted { continue }
      result.append(entry.file)
    }
    for f in base {
      if entries[f.id]?.deleted == true { continue } // 墓碑：从结果中剔除
      if !seen.insert(f.id).inserted { continue }    // 暂存已有更新版，跳过库版本
      result.append(f)
    }
    return result
  }
}

// MARK: - Main View

struct FileSearchView: View {
  @State private var searchText = ""
  @State private var files: [FileMetadata] = []
  @State private var selectedFileIDs = Set<FileMetadata.ID>()
  @State private var showingFolderAlert = false
  @State private var showingRebuildAlert = false
  @State private var showingNewView = false
  @State private var showingIgnoreRules = false
  @State private var showingRebuildFTSAlert = false
  @State private var pendingPath: String = ""
  @State private var searchTask: Task<Void, Never>? = nil
  @State private var totalCount: Int = 0
  @State private var scanStatus: String = ""
  @State private var scannedCount: Int = 0
  @State private var isScanning: Bool = false
  @State private var detailMode: DetailMode = .search
  @State private var sortOption: SortOption = .modificationTime
  @State private var regexMode: Bool = false
  @State private var selectedView: ViewConfig? = nil
  @State private var viewFiles: [FileMetadata] = []
  @State private var isSearching: Bool = false
  @State private var spaceItems: [DirSize] = []
  @State private var spacePath: String = NSHomeDirectory()
  @State private var spaceLoading: Bool = false
  @StateObject private var pendingCache = PendingChangeCache()
  @StateObject private var workspace = WorkspaceManager()
  @StateObject private var viewManager = ViewManager()
  @StateObject private var ignoreRulesManager = IgnoreRulesManager()
  @StateObject private var searchHistory = SearchHistoryManager()
  @FocusState private var searchFieldFocused: Bool
  @State private var showSearchHistory: Bool = false
  @State private var keyMonitor: Any?

  let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

  private var dbManager: FileDatabase? = try? FileDatabase(name: "easyqfiles.db")

  private var displayedFiles: [FileMetadata] {
    switch detailMode {
    case .search: return files
    case .workspace: return workspace.items
    case .view: return viewFiles
    case .space: return []
    }
  }

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("EasyQ")
            .font(.title2.bold())
          Spacer()
          Button(action: { showingRebuildFTSAlert = true }) {
            Image(systemName: "arrow.triangle.2.circlepath")
              .font(.caption)
          }
          .buttonStyle(.plain)
          .help("重建全文索引")
          Button(action: { showingIgnoreRules = true }) {
            Image(systemName: "gear")
              .font(.caption)
          }
          .buttonStyle(.plain)
          .help("排除规则设置")
        }
        .padding(.top, 16)
        .padding(.horizontal)

        // 搜索框
        HStack(spacing: 6) {
          TextField("输入关键词搜索...", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .focused($searchFieldFocused)
            .onSubmit {
              // 回车立即搜索，不等 2 秒防抖
              searchTask?.cancel()
              performSearch()
            }
          Button(action: { regexMode.toggle() }) {
            Text(".*")
              .font(.system(size: 13, weight: .medium, design: .monospaced))
              .foregroundColor(regexMode ? .white : .secondary)
              .frame(width: 24, height: 22)
              .background(regexMode ? Color.accentColor : Color.clear)
              .cornerRadius(4)
          }
          .buttonStyle(.plain)
          .help("正则表达式模式")
        }
        .padding(.horizontal)
        .padding(.top, 12)
          .onChange(of: searchText, perform: { _ in
            // 输入时关闭历史弹窗
            if !searchText.isEmpty {
              DispatchQueue.main.async { showSearchHistory = false }
            }
            searchTask?.cancel()
            searchTask = Task {
              // 2 秒防抖：停止输入 2 秒后才真正发起查询，
              // 避免逐字符触发高频查询打断输入
              try? await Task.sleep(nanoseconds: 2_000_000_000)
              if !Task.isCancelled {
                performSearch()
              }
            }
          })
          .onChange(of: searchFieldFocused, perform: { focused in
            // 延迟到下一帧，避免在布局周期内触发弹窗状态变更
            DispatchQueue.main.async {
              if focused && searchText.isEmpty && !searchHistory.history.isEmpty {
                showSearchHistory = true
              } else if !focused {
                showSearchHistory = false
              }
            }
          })
          .onChange(of: sortOption, perform: { _ in
            performSearch()
          })

        // 搜索历史下拉列表（用 VStack 替代 popover，避免崩溃）
        if showSearchHistory {
          VStack(alignment: .leading, spacing: 0) {
            HStack {
              Text("搜索历史")
                .font(.caption.bold())
              Spacer()
              Button("清除") { searchHistory.clear() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ForEach(searchHistory.history, id: \.self) { item in
              HStack {
                Image(systemName: "clock")
                  .font(.caption)
                  .foregroundColor(.secondary)
                Text(item)
                  .font(.system(size: 13))
                  .lineLimit(1)
                Spacer()
                Button(action: { searchHistory.remove(item) }) {
                  Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 5)
              .contentShape(Rectangle())
              .onTapGesture {
                searchText = item
                showSearchHistory = false
              }
            }
          }
          .background(Color(NSColor.controlBackgroundColor))
          .cornerRadius(6)
          .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
          .padding(.horizontal)
          .transition(.opacity)
        }

        // 视图列表
        viewList

        // 空间分析入口
        spaceEntry

        Spacer()

        // 扫描状态
        if isScanning {
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
              ProgressView()
                .controlSize(.mini)
              Text(scanStatus)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            // 进度条（indeterminate，因为无法预知总量）
            ProgressView()
              .progressViewStyle(.linear)
              .frame(height: 4)
            Text("已扫描 \(scannedCount) 个文件")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
          .padding(.horizontal)
          .padding(.bottom, 8)
        }
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 240)
      .sheet(isPresented: $showingNewView) {
        NewViewSheet(viewManager: viewManager, dbManager: dbManager)
      }
      .sheet(isPresented: $showingIgnoreRules) {
        IgnoreRulesView(manager: ignoreRulesManager)
      }
      .alert("确认同步该目录？", isPresented: $showingFolderAlert) {
        Button("开始扫描") { confirmAndSendToAgent() }
        Button("取消", role: .cancel) { }
      } message: {
        Text("即将深度扫描并更新数据库：\n\(pendingPath)")
      }
      .alert("确认重建索引？", isPresented: $showingRebuildAlert) {
        Button("重建", role: .destructive) { doRebuildIndex() }
        Button("取消", role: .cancel) { }
      } message: {
        Text("将清空全部索引数据并从头扫描，耗时较长。\n此操作不可撤销。")
      }
      .alert("重建全文索引？", isPresented: $showingRebuildFTSAlert) {
        Button("重建") { doRebuildFTS() }
        Button("取消", role: .cancel) { }
      } message: {
        Text("从已有数据重建全文搜索索引，解决搜索找不到文件的问题。")
      }

    } detail: {
      VStack(spacing: 0) {
        // 模式切换 Tab
        Picker("", selection: $detailMode) {
          ForEach(DetailMode.allCases, id: \.self) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 250)
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 4)

        // 排序控制
        if detailMode == .view, let sv = selectedView {
          HStack {
            Text(sv.name)
              .font(.caption.bold())
            Spacer()
            Text("\(viewFiles.count) 个结果")
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .padding(.horizontal)
          .padding(.vertical, 6)
        } else if detailMode == .search && (!files.isEmpty || isSearching) {
          HStack {
            Picker("排序", selection: $sortOption) {
              Text("修改时间").tag(SortOption.modificationTime)
              Text("文件名").tag(SortOption.name)
              Text("大小").tag(SortOption.size)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 250)
            Spacer()
            if isSearching {
              HStack(spacing: 4) {
                ProgressView()
                  .controlSize(.mini)
                Text("搜索中...")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            } else {
              Text("\(files.count) 个结果")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
          .padding(.horizontal)
          .padding(.vertical, 6)
        }

        // 空间分析模式：独立视图（面包屑 + 大小排行 + 下钻）
        if detailMode == .space {
          SpaceDetailView(
            path: spacePath,
            items: spaceItems,
            loading: spaceLoading,
            homePath: NSHomeDirectory(),
            onDrill: { path in loadSpace(path: path) },
            onReveal: { path in revealInFinder(url: path) }
          )
        } else {
        Table(displayedFiles, selection: $selectedFileIDs) {
          TableColumn("文件名", value: \.name)
            .width(min: 150, ideal: 220)
          TableColumn("路径") { item in
            PathCellText(path: item.parent)
          }
          .width(min: 200, ideal: 520)
          TableColumn("大小", value: \.sizeString)
          TableColumn("类型") { item in
            TypeCellText(isDir: item.isDir)
          }
          TableColumn("修改时间", value: \.modificationDate)
        }
        // FileMetadata 遵循 Transferable，Table 自动支持拖拽到其他 App
        .contextMenu {
          let selectedFiles = displayedFiles.filter { selectedFileIDs.contains($0.id) }
          if !selectedFiles.isEmpty {
            if selectedFiles.count == 1 {
              Button("在 Finder 中显示") {
                revealInFinder(url: selectedFiles[0].parent + "/" + selectedFiles[0].name)
              }
            } else {
              Button("在 Finder 中显示 (\(selectedFiles.count) 项)") {
                for file in selectedFiles {
                  revealInFinder(url: file.parent + "/" + file.name)
                }
              }
            }
            Divider()
            if detailMode == .search || detailMode == .view {
              Button("添加到工作区 (\(selectedFiles.count) 项)") {
                for file in selectedFiles { workspace.add(file) }
              }
            } else if detailMode == .workspace {
              Button("从工作区移除 (\(selectedFiles.count) 项)") {
                for file in selectedFiles { workspace.remove(file) }
              }
            }
            Divider()
            Button("复制路径") {
              let paths = selectedFiles.map { $0.parent + "/" + $0.name }
              NSPasteboard.general.clearContents()
              NSPasteboard.general.writeObjects(paths as [NSPasteboardWriting])
            }
            if selectedFiles.count == 1 {
              Button("用默认应用打开") {
                let url = URL(fileURLWithPath: selectedFiles[0].parent + "/" + selectedFiles[0].name)
                NSWorkspace.shared.open(url)
              }
            }
            Button("移到废纸篓", role: .destructive) {
              for file in selectedFiles {
                let url = URL(fileURLWithPath: file.parent + "/" + file.name)
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
              }
            }
          }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          if let first = selectedFileIDs.first,
             let file = displayedFiles.first(where: { $0.id == first }) {
            revealInFinder(url: file.parent + "/" + file.name)
          }
        }
        .onTapGesture {
          if NSEvent.modifierFlags.contains(.command) {
            for id in selectedFileIDs {
              if let file = displayedFiles.first(where: { $0.id == id }) {
                revealInFinder(url: file.parent + "/" + file.name)
              }
            }
          }
        }
        .overlay {
          if isSearching && displayedFiles.isEmpty {
            VStack(spacing: 8) {
              ProgressView()
                .controlSize(.regular)
              Text("正在搜索...")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          } else if displayedFiles.isEmpty {
            let msg: String = {
              switch detailMode {
              case .workspace: return "工作区为空，右键搜索结果可添加"
              case .search: return "没有找到匹配的文件"
              case .view: return "该视图暂无匹配文件"
              case .space: return "该目录暂无数据"
              }
            }()
            Text(msg).foregroundStyle(.secondary)
          }
        }

        // 文件信息面板
        if selectedFileIDs.count == 1,
           let first = selectedFileIDs.first,
           let file = displayedFiles.first(where: { $0.id == first }) {
          Divider()
          FileInfoPanel(file: file)
        }
        }
      }
    }
    .focusedSceneValue(\.indexCount, totalCount)
    .focusedSceneValue(\.selectFolder, selectFolder)
    .focusedSceneValue(\.rebuildIndex, { showingRebuildAlert = true })
    .focusedSceneValue(\.rebuildViews, rebuildAllViews)
    .onAppear {
      refreshData()
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        // 空格预览：搜索框未聚焦且有选中文件时
        if event.keyCode == 49 && !searchFieldFocused {
          if let first = selectedFileIDs.first,
             let file = displayedFiles.first(where: { $0.id == first }) {
            let url = URL(fileURLWithPath: file.parent + "/" + file.name)
            QuickLookHelper.shared.toggle(url)
            return nil
          }
        }
        return event
      }
    }
    .onDisappear {
      if let monitor = keyMonitor {
        NSEvent.removeMonitor(monitor)
        keyMonitor = nil
      }
    }
    .onReceive(timer) { _ in refreshData() }
    // Agent 暂存层增量推送：只更新缓存，供下一次搜索合并。
    // 注意：不能在这里自动 performSearch()——performSearch 会发 queryPending，
    // Agent 回推 pendingChanges 又回到这里，形成"查询→推送→重查"死循环（结果闪烁、选中丢失）
    .onReceive(DistributedNotificationCenter.default().publisher(for: NSNotification.Name("com.easyq.agent.pendingChanges"))) { notification in
      if let info = notification.userInfo,
         let updates = info["updates"] as? [[String: Any]],
         let deletes = info["deletes"] as? [[String: Any]] {
        pendingCache.apply(updates: updates, deletes: deletes)
      }
    }
    // Agent 已把增量落库：清空本地暂存缓存（库已是权威数据），静默重查一次
    .onReceive(DistributedNotificationCenter.default().publisher(for: NSNotification.Name("com.easyq.agent.pendingFlushed"))) { _ in
      pendingCache.removeAll()
      if !searchText.isEmpty && detailMode == .search {
        performSearch()
      }
    }
    .onReceive(DistributedNotificationCenter.default().publisher(for: NSNotification.Name("com.easyq.agent.scanComplete"))) { _ in
      scanStatus = ""
      isScanning = false
      scannedCount = 0
      rebuildAllViews()
    }
    .onReceive(DistributedNotificationCenter.default().publisher(for: NSNotification.Name("com.easyq.agent.scanProgress"))) { notification in
      if let info = notification.userInfo,
         let path = info["currentPath"] as? String,
         let pending = info["pendingTasks"] as? Int,
         let count = info["scannedCount"] as? Int {
        isScanning = true
        scannedCount = count
        let shortPath = path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        scanStatus = "扫描中: \(shortPath) (\(pending) 队列)"
      }
    }
  }

  // MARK: - 空间分析入口

  private var spaceEntry: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("空间")
          .font(.caption.bold())
          .foregroundColor(.secondary)
        Spacer()
      }
      .padding(.horizontal)
      .padding(.top, 12)

      HStack {
        Image(systemName: "internaldrive")
          .foregroundColor(.orange)
          .font(.caption)
        Text("磁盘占用分析")
          .font(.system(size: 13))
          .lineLimit(1)
        Spacer()
        if detailMode == .space && spaceLoading {
          ProgressView()
            .controlSize(.mini)
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 4)
      .background(detailMode == .space ? Color.accentColor.opacity(0.2) : Color.clear)
      .cornerRadius(4)
      .contentShape(Rectangle())
      .onTapGesture {
        if detailMode == .space {
          // 已在空间模式：点入口回到根目录
          loadSpace(path: NSHomeDirectory())
        } else {
          detailMode = .space
          loadSpace(path: spacePath)
        }
      }
      .contextMenu {
        Button("回到主目录") { loadSpace(path: NSHomeDirectory()) }
      }
    }
  }

  private func loadSpace(path: String) {
    spacePath = path
    spaceLoading = true
    detailMode = .space
    DispatchQueue.global(qos: .userInitiated).async {
      let results = self.dbManager?.topSizes(under: path) ?? []
      DispatchQueue.main.async {
        self.spaceItems = results
        self.spaceLoading = false
      }
    }
  }

  // MARK: - 视图列表

  private var viewList: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("视图")
          .font(.caption.bold())
          .foregroundColor(.secondary)
        Spacer()
        Button(action: { showingNewView = true }) {
          Image(systemName: "plus")
            .font(.caption)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal)
      .padding(.top, 12)

      ForEach(viewManager.views) { view in
        let isSelected = selectedView?.id == view.id && detailMode == .view
        HStack {
          Image(systemName: "folder")
            .foregroundColor(.blue)
            .font(.caption)
          Text(view.name)
            .font(.system(size: 13))
            .lineLimit(1)
          Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
          selectView(view)
        }
        .contextMenu {
          Button("重建") {
            if let db = dbManager {
              viewManager.rebuildView(view, db: db)
            }
          }
          Button("在 Finder 中打开") {
            revealInFinder(url: viewManager.viewDirectory(for: view).path)
          }
          Divider()
          Button("删除", role: .destructive) {
            viewManager.remove(view)
          }
        }
      }
    }
  }

  // MARK: - Actions

  func refreshData() {
    DispatchQueue.global(qos: .utility).async {
      let count = self.dbManager?.count() ?? 0
      DispatchQueue.main.async { self.totalCount = count }
    }
  }

  private func rebuildAllViews() {
    guard let db = dbManager else { return }
    DispatchQueue.global(qos: .utility).async {
      viewManager.rebuildAll(db: db)
    }
  }

  private func selectView(_ view: ViewConfig) {
    selectedView = view
    detailMode = .view
    guard let db = dbManager else { return }
    let rules = view.rules
    DispatchQueue.global(qos: .userInitiated).async {
      let results = db.searchWithRules(rules)
      DispatchQueue.main.async {
        self.viewFiles = results
      }
    }
  }

  private func selectFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.message = "请选择要强制刷新的文件夹"
    panel.begin { response in
      if response == .OK, let url = panel.url {
        let path = url.path(percentEncoded: false).cleanedPath()
        self.pendingPath = path
        self.showingFolderAlert = true
      }
    }
  }

  private func confirmAndSendToAgent() {
    isScanning = true
    scannedCount = 0
    scanStatus = "正在扫描 \(pendingPath)..."
    DistributedNotificationCenter.default().postNotificationName(
      NSNotification.Name("com.easyq.agent.forceScan"),
      object: nil,
      userInfo: ["targetPath": pendingPath],
      deliverImmediately: true
    )
  }

  private func doRebuildIndex() {
    isScanning = true
    scannedCount = 0
    scanStatus = "正在重建索引..."
    DistributedNotificationCenter.default().postNotificationName(
      NSNotification.Name("com.easyq.agent.forceScan"),
      object: nil,
      userInfo: ["rebuild": true],
      deliverImmediately: true
    )
  }

  private func doRebuildFTS() {
    guard let db = dbManager else { return }
    isScanning = true
    scanStatus = "正在重建全文索引..."
    DispatchQueue.global(qos: .userInitiated).async {
      let success = db.rebuildFTS()
      DispatchQueue.main.async {
        isScanning = false
        scanStatus = ""
        if success {
          // 重建后刷新搜索结果
          performSearch()
        }
      }
    }
  }

  private var searchKeywords: [String] {
    searchText.split(separator: " ").map { String($0) }.filter { !$0.isEmpty }
  }

  /// 搜索结果代际：每次新搜索 +1。回包时若代际已过期（用户又输入了），结果直接丢弃。
  /// 防止旧查询慢返回覆盖新结果导致的"闪回"。
  @State private var searchGeneration = 0

  private func performSearch() {
    let kws = searchKeywords
    if kws.isEmpty {
      files = []
      isSearching = false
      return
    }
    searchHistory.add(searchText)
    let sort = sortOption
    let regex = regexMode
    isSearching = true
    searchGeneration += 1
    let generation = searchGeneration
    let inputAtSearch = searchText
    // 向 Agent 请求一次暂存增量（异步通知往返，Agent 响应经 pendingChanges 推送更新缓存；
    // 本次搜索先用当前缓存合并，下次搜索自然带上最新增量——最终一致，无需等待）
    DistributedNotificationCenter.default().postNotificationName(
      NSNotification.Name("com.easyq.agent.queryPending"),
      object: nil,
      userInfo: [:],
      deliverImmediately: true
    )
    // 查询走 DBManager 专用串行队列，不碰主线程；UI 保持完全流畅
    dbManager?.searchFiles(keywords: kws, sort: sort, regex: regex) { results in
      DispatchQueue.main.async {
        // 代际校验：只接受最新一次搜索的结果（旧的慢查询直接丢弃）
        guard generation == self.searchGeneration else { return }
        // 主线程合并暂存增量（@Published 状态只在主线程访问）
        self.files = self.pendingCache.merged(with: results)
        self.detailMode = .search
        self.isSearching = false
      }
    }
  }

  func revealInFinder(url: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: url)])
  }
}

// MARK: - 表格小组件（拆分降低 body 类型推断复杂度）

private struct PathCellText: View {
  let path: String
  var body: some View {
    Text(path)
      .font(.system(size: 11))
      .foregroundColor(.secondary)
      .lineLimit(1)
      .truncationMode(.middle)
      .help(path)
  }
}

private struct TypeCellText: View {
  let isDir: Bool
  var body: some View {
    Text(isDir ? "文件夹" : "文件")
  }
}

// MARK: - 空间分析视图

/// 磁盘占用排行：面包屑 + Top 列表（点击行下钻，右键 Finder 显示）
private struct SpaceDetailView: View {
  let path: String
  let items: [DirSize]
  let loading: Bool
  let homePath: String
  let onDrill: (String) -> Void
  let onReveal: (String) -> Void

  /// 面包屑组件路径：~ 压缩 home
  private var displayPath: String {
    path.replacingOccurrences(of: homePath, with: "~")
  }

  private var crumbs: [(label: String, path: String)] {
    // 从 home 开始的每一段都可点
    var out: [(String, String)] = []
    if path.hasPrefix(homePath) {
      out.append(("~", homePath))
      let rest = String(path.dropFirst(homePath.count + 1))
      if !rest.isEmpty {
        var acc = homePath
        for seg in rest.split(separator: "/") {
          acc += "/" + seg
          out.append((String(seg), acc))
        }
      }
    } else {
      out.append(("/", "/"))
      for seg in path.split(separator: "/") {
        out.append((String(seg), "/" + seg))
      }
    }
    return out
  }

  private var grandTotal: Int64 {
    items.reduce(0) { $0 + $1.totalSize }
  }

  var body: some View {
    VStack(spacing: 0) {
      // 面包屑 + 汇总
      HStack(spacing: 4) {
        ForEach(Array(crumbs.enumerated()), id: \.offset) { idx, crumb in
          if idx > 0 {
            Image(systemName: "chevron.right")
              .font(.system(size: 9))
              .foregroundColor(.secondary)
          }
          Button(crumb.label) {
            onDrill(crumb.path)
          }
          .buttonStyle(.plain)
          .foregroundColor(idx == crumbs.count - 1 ? .primary : .accentColor)
          .font(.system(size: 12, weight: idx == crumbs.count - 1 ? .semibold : .regular))
          .lineLimit(1)
        }
        Spacer()
        if loading {
          ProgressView().controlSize(.mini)
        } else {
          Text("合计 \(ByteCountFormatter.string(fromByteCount: grandTotal, countStyle: .file)) · Top \(items.count)")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)

      Divider()

      if items.isEmpty && !loading {
        Spacer()
        Text("该目录暂无索引数据")
          .foregroundColor(.secondary)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
              SpaceRowView(
                item: item,
                rank: idx + 1,
                maxTotal: items.first?.totalSize ?? 1
              )
              .contentShape(Rectangle())
              .onTapGesture { onDrill(item.path) }
              .contextMenu {
                Button("下钻") { onDrill(item.path) }
                Button("在 Finder 中显示") { onReveal(item.path) }
                Divider()
                Button("复制路径") {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.writeObjects([item.path] as [NSPasteboardWriting])
                }
              }
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
    .background(Color(NSColor.controlBackgroundColor))
  }
}

private struct SpaceRowView: View {
  let item: DirSize
  let rank: Int
  let maxTotal: Int64

  var body: some View {
    HStack(spacing: 8) {
      Text(String(format: "%3d", rank))
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.secondary)
        .frame(width: 34, alignment: .trailing)
      Image(systemName: "folder.fill")
        .font(.system(size: 11))
        .foregroundColor(.blue)
      Text(item.name)
        .font(.system(size: 13))
        .lineLimit(1)
        .help(item.path)
      // 占比条
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.secondary.opacity(0.15))
          Capsule()
            .fill(LinearGradient(colors: [.orange, .orange.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
            .frame(width: max(2, geo.size.width * ratio))
        }
      }
      .frame(height: 6)
      Spacer()
      Text(item.sizeString)
        .font(.system(size: 12, design: .monospaced))
        .foregroundColor(.secondary)
        .frame(minWidth: 70, alignment: .trailing)
    }
    .padding(.horizontal)
    .padding(.vertical, 5)
    .background(
      Color.primary.opacity(0.001) // 命中区
    )
  }

  private var ratio: CGFloat {
    maxTotal > 0 ? CGFloat(item.totalSize) / CGFloat(maxTotal) : 0
  }
}

// MARK: - 新建视图 Sheet

struct NewViewSheet: View {
  @ObservedObject var viewManager: ViewManager
  var dbManager: FileDatabase?
  @Environment(\.dismiss) var dismiss

  @State private var name = ""
  @State private var extensionsText = ""
  @State private var keywordsText = ""
  @State private var useDateFilter = false
  @State private var daysBack = 7
  @State private var customSQL = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("新建视图")
        .font(.headline)

      TextField("视图名称", text: $name)
        .textFieldStyle(.roundedBorder)

      Divider()

      Text("过滤规则")
        .font(.subheadline.bold())

      HStack {
        Text("扩展名:")
          .frame(width: 70, alignment: .trailing)
        TextField("pdf, docx, pptx", text: $extensionsText)
          .textFieldStyle(.roundedBorder)
      }

      HStack {
        Text("关键词:")
          .frame(width: 70, alignment: .trailing)
        TextField("report, 2024", text: $keywordsText)
          .textFieldStyle(.roundedBorder)
      }

      Toggle(isOn: $useDateFilter) {
        HStack {
          Text("最近修改:")
            .frame(width: 70, alignment: .trailing)
          if useDateFilter {
            TextField("", value: $daysBack, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 50)
            Text("天内")
          }
        }
      }

      VStack(alignment: .leading) {
        Text("自定义 SQL (可选):")
          .font(.caption)
          .foregroundColor(.secondary)
        TextField("size > 1000000", text: $customSQL)
          .textFieldStyle(.roundedBorder)
      }

      HStack {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("创建") { createView() }
          .keyboardShortcut(.defaultAction)
          .disabled(name.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 380)
  }

  private func createView() {
    var rules: [ViewRule] = []

    let exts = extensionsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    if !exts.isEmpty {
      rules.append(.extensions(exts))
    }

    let kws = keywordsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if !kws.isEmpty {
      rules.append(.filenameContains(kws))
    }

    if useDateFilter && daysBack > 0 {
      let date = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date())!
      rules.append(.modifiedAfter(date))
    }

    let sql = customSQL.trimmingCharacters(in: .whitespaces)
    if !sql.isEmpty {
      rules.append(.customSQL(sql))
    }

    guard !rules.isEmpty else { return }

    let view = ViewConfig(name: name, rules: rules)
    viewManager.add(view, db: dbManager)
    dismiss()
  }
}
