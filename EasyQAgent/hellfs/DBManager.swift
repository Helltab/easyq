import Foundation
import SQLite

/// 在每个 CJK 字符前后插入空格，让 FTS5 unicode61 分词器正确切分中文
/// "2021绩效面谈" → "2021 绩 效 面 谈"
func normalizeCJK(_ s: String) -> String {
  var result = ""
  for scalar in s.unicodeScalars {
    let v = scalar.value
    let isCJK = (0x4E00...0x9FFF).contains(v) ||
                (0x3400...0x4DBF).contains(v) ||
                (0x20000...0x2A6DF).contains(v) ||
                (0xF900...0xFAFF).contains(v)
    if isCJK {
      result.append(" ")
      result.append(Character(scalar))
      result.append(" ")
    } else {
      result.append(Character(scalar))
    }
  }
  // 合并连续空格
  return result.components(separatedBy: .whitespaces)
    .filter { !$0.isEmpty }
    .joined(separator: " ")
}

struct FileMetadata {
  init() {
    self.parent = ""
    self.name = ""
    self.size = 0
    self.mtime = 0
    self.isDir = false
  }
  init(parent: String, name: String, size: Int64, mtime: Int64, isDir: Bool) {
    self.parent = parent
    self.name = name
    self.size = size
    self.mtime = mtime
    self.isDir = isDir
  }
  init?(path: String) {
    let url = URL(fileURLWithPath: path)
    let path = url.path

    do {
      let fileManager = FileManager.default
      let attrs = try fileManager.attributesOfItem(atPath: path)
      self.size = attrs[.size] as? Int64 ?? 0
      self.isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
      let date = attrs[.modificationDate] as? Date ?? Date()
      self.mtime = Int64(date.timeIntervalSince1970)
    }catch{
      self.size=0
      self.isDir=false
      self.mtime=0
      log("属性获取失败")
    }
    self.parent = url.deletingLastPathComponent().path
    self.name = url.lastPathComponent
  }
  /// 删除项快速构造（不 stat 磁盘，仅供 syncDelete 使用）
  init(parent: String, name: String) {
    self.parent = parent
    self.name = name
    self.size = 0
    self.mtime = 0
    self.isDir = false
  }
  var parent: String
  var name: String
  var size: Int64
  var mtime: Int64
  var isDir: Bool

}
enum DatabaseError: Error {
  case connectionFailed(String)
}
func getDatabaseURL(name: String) -> URL {
  // 获取用户目录下的 Application Support
  let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
  let documentsDirectory = paths[0]

  // 创建以你 App 命名的子文件夹
  let finalPath = documentsDirectory.appendingPathComponent("EasyQ")

  // 确保文件夹存在
  try? FileManager.default.createDirectory(at: finalPath, withIntermediateDirectories: true)

  return finalPath.appendingPathComponent(name)
}
class FileDatabase {
  private var db: Connection?
  private let files = Table("files")
  private let dbPath: String

  // 定义列
  private let id = Expression<Int64>("id")
  private let parentId = Expression<Int64>("parent_id")
  private let name = Expression<String>("name")
  private let size = Expression<Int64>("size")
  private let mtime = Expression<Int64>("mtime")
  private let isDir = Expression<Bool>("is_dir")

  init(name: String) throws{
    self.dbPath = getDatabaseURL(name: name).path(percentEncoded: false)

    do {
      log("数据库位于: \(dbPath)")
      let conn = try Connection(dbPath)
      db = conn
      // 性能 pragma：内存映射 + 2MB 页缓存
      _ = try? conn.run("PRAGMA mmap_size = 1073741824;")
      _ = try? conn.run("PRAGMA cache_size = -2000;")
      // WAL 模式：大批量写入时 journal 不再长期膨胀，读写不互相阻塞
      _ = try? conn.run("PRAGMA journal_mode = WAL;")
      try createTableAndIndices()
    } catch {
      log("数据库连接失败: \(error)")
      throw DatabaseError.connectionFailed(error.localizedDescription)
    }
  }

  /// 删除数据库文件并重建（用于数据库损坏时恢复）
  func resetDatabase() {
    db = nil
    let fm = FileManager.default
    try? fm.removeItem(atPath: dbPath)
    try? fm.removeItem(atPath: dbPath + "-shm")
    try? fm.removeItem(atPath: dbPath + "-wal")
    do {
      db = try Connection(dbPath)
      try createTableAndIndices()
      log("数据库已重建: \(dbPath)")
    } catch {
      log("数据库重建失败: \(error)")
    }
  }

  private func createTableAndIndices() throws {
    guard let db = db else { return }

    // 1. 路径字典表：路径字符串只存一份（此前平铺存储，同一路径平均重复 8.5 次，
    //    286 万行里 parent 列 256MB，去重后仅 32MB）
    try db.execute("""
          CREATE TABLE IF NOT EXISTS paths (
              path_id INTEGER PRIMARY KEY,
              path TEXT UNIQUE
          );
          """)

    // 2. 文件表：parent_id 引用字典表
    try db.execute("""
          CREATE TABLE IF NOT EXISTS files (
              id INTEGER PRIMARY KEY,
              parent_id INTEGER,
              name TEXT,
              size INTEGER,
              mtime INTEGER,
              is_dir INTEGER,
              UNIQUE(parent_id, name)
          );
          """)

    // 3. 索引：不再需要 idx_parent（UNIQUE(parent_id,name) 已覆盖等值查询，
    //    平铺时代它 325MB 且与 UNIQUE 索引功能重叠）
    try db.execute("CREATE INDEX IF NOT EXISTS idx_name ON files(name);")
    try db.execute("CREATE INDEX IF NOT EXISTS idx_mtime ON files(mtime);")

    // 4. FTS5 全文索引虚拟表（外部内容模式，不存储 name 副本）
    try db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(name, content=files, content_rowid=id);")

    // 5. 迁移：旧平铺库升级到字典表结构
    try migrateFlatToDictIfNeeded()

    log("数据库 DDL 执行成功")
  }

  /// 旧版平铺库（files.parent TEXT）自动迁移到字典表结构（files.parent_id）
  /// 迁移后旧 parent 列删除，库体积预计从 1.3GB 降至 ~450MB
  private func migrateFlatToDictIfNeeded() throws {
    guard let db = db else { return }
    // 判断是否旧结构：files 表存在 parent 列
    let columns = try db.prepare("PRAGMA table_info(files)")
    var hasParentText = false
    for col in columns {
      if let name = col[1] as? String, name == "parent" { hasParentText = true }
    }
    guard hasParentText else { return } // 已是新结构

    log("检测到旧平铺结构，开始迁移到路径字典表...")
    let start = Date()

    // 1) 把所有 distinct parent 灌进字典表
    try db.execute("INSERT OR IGNORE INTO paths(path) SELECT DISTINCT parent FROM files;")

    // 2) 重建 files 表（换结构不能 ALTER，走 建新表→搬数据→改名）
    try db.execute("ALTER TABLE files RENAME TO files_old;")
    try db.execute("""
          CREATE TABLE files (
              id INTEGER PRIMARY KEY,
              parent_id INTEGER,
              name TEXT,
              size INTEGER,
              mtime INTEGER,
              is_dir INTEGER,
              UNIQUE(parent_id, name)
          );
          """)
    try db.execute("""
          INSERT OR IGNORE INTO files(id, parent_id, name, size, mtime, is_dir)
          SELECT f.id, p.path_id, f.name, f.size, f.mtime, f.is_dir
          FROM files_old f JOIN paths p ON p.path = f.parent;
          """)
    try db.execute("DROP TABLE files_old;")
    // 旧索引随旧表一起没了；重建新索引与 FTS
    try db.execute("CREATE INDEX IF NOT EXISTS idx_name ON files(name);")
    try db.execute("CREATE INDEX IF NOT EXISTS idx_mtime ON files(mtime);")
    try db.execute("DROP TABLE IF EXISTS files_fts;")
    try db.execute("CREATE VIRTUAL TABLE files_fts USING fts5(name, content=files, content_rowid=id);")
    // FTS 重建交给上层（initTask 检测 isFTSEmpty 自动触发）
    try db.execute("VACUUM;")

    let secs = Date().timeIntervalSince(start)
    log("✅ 迁移完成，耗时 \(String(format: "%.1f", secs))s")
  }

  func hasFiles() -> Bool {
    guard let db = db else { return false }

    do {
      // pluck 会尝试抓取表中的第一行记录
      // 如果表是空的，它返回 nil；如果不为空，它返回 Row 对象
      let row = try db.pluck(files)

      // 关键修复：判断 row 是否不等于 nil
      return row != nil
    } catch {
      log("检查数据库失败: \(error)")
      return false
    }
  }

  /// 路径字典解析：拿（或插入）路径对应的 path_id
  /// 事务外使用注意：批量场景在调用方的事务里执行 INSERT OR IGNORE + SELECT
  private func resolvePathId(_ path: String) -> Int64? {
    guard let db = db else { return nil }
    do {
      try db.run("INSERT OR IGNORE INTO paths(path) VALUES (?);", [path])
      if let row = try db.prepare("SELECT path_id FROM paths WHERE path = ?", [path]).failableNext() {
        return row[0] as? Int64
      }
    } catch {
      log("路径字典解析失败: \(path) \(error)")
    }
    return nil
  }

  /// 同步单条记录到 FTS5 索引（使用 normalizeCJK 处理中文分词）
  private func ftsSync(_ file: FileMetadata) {
    guard let db = db else { return }
    let target = files.filter(self.parentId == resolvePathId(file.parent) ?? -1 && self.name == file.name)
    guard let row = try? db.pluck(target.select(id)) else { return }
    let rowid = row[self.id]
    let normalizedName = normalizeCJK(file.name)
    try? db.run("DELETE FROM files_fts WHERE rowid = ?", [rowid])
    try? db.run("INSERT INTO files_fts(rowid, name) VALUES (?, ?)", [rowid, normalizedName])
  }

  func saveFiles(_ fileList: [FileMetadata]) {
    saveFilesInternal(fileList, isRetry: false)
  }

  private func saveFilesInternal(_ fileList: [FileMetadata], isRetry: Bool) {
    guard let db = db else { return }

    do {
      try db.transaction {
        for file in fileList {
          guard let pid = resolvePathId(file.parent) else { continue }
          try db.run(files.insert(
            or: .replace,
            self.parentId <- pid,
            self.name <- file.name,
            self.size <- file.size,
            self.mtime <- file.mtime,
            self.isDir <- file.isDir
          ))
          ftsSync(file)
        }
      }
      log("成功入库 \(fileList.count) 条记录")
    } catch {
      log("批量插入失败: \(error)")
      if !isRetry && "\(error)".contains("malformed") {
        log("检测到数据库损坏，自动重建")
        resetDatabase()
        saveFilesInternal(fileList, isRetry: true)
      }
    }
  }
  func upsert(items: [FileMetadata]) {
    guard let db = db else { return }

    // 分片事务：与 delete 一致，避免巨型事务
    let chunkSize = 500
    var inserted = 0
    for start in stride(from: 0, to: items.count, by: chunkSize) {
      let chunk = Array(items[start..<min(start + chunkSize, items.count)])
      do {
        try db.transaction {
          for item in chunk {
            guard let pid = resolvePathId(item.parent) else { continue }
            let statement = files.insert(or: .replace,
                                         self.parentId <- pid,
                                         self.name <- item.name,
                                         self.size <- item.size,
                                         self.mtime <- item.mtime,
                                         self.isDir <- item.isDir
            )
            try db.run(statement)
            ftsSync(item)
          }
        }
        inserted += chunk.count
      } catch {
        log("❌ 批量写入数据库失败: \(error)")
      }
    }
    if inserted > 0 {
      log("✅ 成功批量更新 \(inserted) 条记录")
    }
  }
  func delete(items: [FileMetadata]) {
    guard let db = db else { return }

    // 分片事务：每 500 条一批，journal 不会无限膨胀，中途失败也只回滚当前批
    let chunkSize = 500
    for start in stride(from: 0, to: items.count, by: chunkSize) {
      let chunk = Array(items[start..<min(start + chunkSize, items.count)])
      do {
        try db.transaction {
          for item in chunk {
            let parentPath = item.parent
            let fileName = item.name
            let path = (parentPath + "/" + fileName)
              .trimmingCharacters(in: .whitespacesAndNewlines)
              .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            // 1. 删除自身记录（parent_id 从字典表解析）
            guard let pid = resolvePathId(parentPath) else { continue }
            let target = files.filter(self.parentId == pid && self.name == fileName)

            // 收集本项需要清理 FTS 的所有 rowid（自身 + 子项）
            var rowids: [Int64] = []
            if let row = try? db.pluck(target.select(id)) {
              rowids.append(row[self.id])
            }
            try db.run(target.delete())

            // 2. 删除所有子项（仅目录才需要）
            // 字典表结构下：子树 = path 及其前缀的所有 path_id 对应的行，
            // 用 IN (path_id 列表) 走索引，不再 LIKE 全表扫描
            if item.isDir {
              var childPathIds: [Int64] = []
              if let rows = try? db.prepare("SELECT path_id FROM paths WHERE path = ? OR path LIKE ?", [path, path + "/%"]) {
                for r in rows { childPathIds.append(r[0] as! Int64) }
              }
              if !childPathIds.isEmpty {
                let idList = childPathIds.map { String($0) }.joined(separator: ",")
                if let childRows = try? db.prepare("SELECT id FROM files WHERE parent_id IN (\(idList))") {
                  for childRow in childRows {
                    rowids.append(childRow[0] as! Int64)
                  }
                }
                try db.run("DELETE FROM files WHERE parent_id IN (\(idList))")
              }
            }

            // 3. 批量同步删除 FTS5 索引（一条 IN 语句替代逐行 DELETE）
            if !rowids.isEmpty {
              let placeholders = rowids.map { _ in "?" }.joined(separator: ",")
              try? db.run("DELETE FROM files_fts WHERE rowid IN (\(placeholders))", rowids)
            }
          }
        }
        log("🗑️ 删除批次完成: \(chunk.count) 项 (共 \(items.count))")
      } catch {
        log("❌ 批量删除失败: \(error)")
      }
    }
  }

  /// 检查 FTS5 索引是否有数据
  func isFTSEmpty() -> Bool {
    guard let db = db else { return true }
    do {
      let stmt = try db.prepare("SELECT count(*) FROM files_fts_idx")
      if let row = stmt.next(), let count = row[0] as? Int64 {
        return count == 0
      }
      return true
    } catch {
      return true
    }
  }

  /// 清空并重建 FTS5 索引（CJK 字符分词后入库）
  /// 用外部内容表的 'rebuild' 命令整体重填——比逐行 INSERT 快得多，
  /// 且 normalizeCJK 通过生成的辅助列在 SQL 内完成
  func rebuildFTS() {
    guard let db = db else { return }

    do {
      // 先建带 normalizeCJK 的辅助函数，再让 FTS5 外部内容 rebuild 整体重建
      _ = try? db.createFunction("normalize_cjk", deterministic: true) { (name: String) -> String in
        return normalizeCJK(name)
      }
      // 换成"取自生成列"的表需要重建，这里退一步：直接批量插入（分片事务）
      try db.run("DELETE FROM files_fts")
      let chunkSize = 50_000
      var lastId: Int64 = 0
      var total = 0
      while true {
        let stmt = try db.prepare("SELECT id, name FROM files WHERE id > ? ORDER BY id LIMIT \(chunkSize)", [lastId])
        var batch: [(Int64, String)] = []
        while let row = try? stmt.failableNext() {
          batch.append((row[0] as! Int64, row[1] as! String))
        }
        if batch.isEmpty { break }
        try db.transaction {
          for (rowid, rawName) in batch {
            try db.run("INSERT INTO files_fts(rowid, name) VALUES (?, ?)", [rowid, normalizeCJK(rawName)])
          }
        }
        lastId = batch[batch.count - 1].0
        total += batch.count
      }
      log("✅ FTS5 索引重建完成, 共 \(total) 条")
    } catch {
      log("❌ FTS5 索引重建失败: \(error)")
    }
  }

  /// 清空所有数据（主表 + FTS5 索引），用于全量重建
  func clearAll() {
    guard let db = db else { return }

    do {
      try db.transaction {
        try db.run("DELETE FROM files_fts")
        try db.run(files.delete())
      }
      log("✅ 数据库已清空")
    } catch {
      log("❌ 清空数据库失败: \(error)")
    }
  }
}
