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
  private let parent = Expression<String>("parent")
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

    // 1. 创建表 (直接执行原生 SQL)
    let createTableSQL = """
          CREATE TABLE IF NOT EXISTS files (
              id INTEGER PRIMARY KEY,
              parent TEXT,
              name TEXT,
              size INTEGER,
              mtime INTEGER,
              is_dir INTEGER,
              UNIQUE(parent, name)
          );
          """
    try db.execute(createTableSQL)

    // 2. 创建索引 (直接执行原生 SQL)
    // 注意：SQL 语法中已经包含了 IF NOT EXISTS，防止重复创建报错
    try db.execute("CREATE INDEX IF NOT EXISTS idx_parent ON files(parent);")
    try db.execute("CREATE INDEX IF NOT EXISTS idx_name ON files(name);")
    try db.execute("CREATE INDEX IF NOT EXISTS idx_mtime ON files(mtime);")

    // 3. 创建 FTS5 全文索引虚拟表（外部内容模式，不存储 name 副本）
    try db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(name, content=files, content_rowid=id);")

    log("数据库 DDL 执行成功")
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

  /// 同步单条记录到 FTS5 索引（使用 normalizeCJK 处理中文分词）
  private func ftsSync(_ file: FileMetadata) {
    guard let db = db else { return }
    let target = files.filter(self.parent == file.parent && self.name == file.name)
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
          try db.run(files.insert(
            or: .replace,
            self.parent <- file.parent,
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
            let statement = files.insert(or: .replace,
                                         self.parent <- item.parent,
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
            // 1. 删除自身记录
            let target = files.filter(self.parent == parentPath && self.name == fileName)

            // 收集本项需要清理 FTS 的所有 rowid（自身 + 子项）
            var rowids: [Int64] = []
            if let row = try? db.pluck(target.select(id)) {
              rowids.append(row[self.id])
            }
            try db.run(target.delete())

            // 2. 删除所有子项（仅目录才需要）
            // 此前不管是不是目录都做 parent LIKE 'path%' —— LIKE 前缀匹配
            // 用不了索引 = 全表扫描，38 万项 × 全表扫描烧掉一整核几十小时
            if item.isDir {
              let children = files.filter(self.parent.like("\(path)%"))
              if let childRows = try? db.prepare(children.select(id)) {
                for childRow in childRows {
                  rowids.append(childRow[self.id])
                }
              }
              try db.run(children.delete())
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
  func rebuildFTS() {
    guard let db = db else { return }

    do {
      try db.transaction {
        try db.run("DELETE FROM files_fts")
        // 批量插入分词后的名称
        for row in try db.prepare(files.select(id, name)) {
          let rowid = row[self.id]
          let normalizedName = normalizeCJK(row[self.name])
          try db.run("INSERT INTO files_fts(rowid, name) VALUES (?, ?)", [rowid, normalizedName])
        }
      }
      log("✅ FTS5 索引重建完成")
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
