import Foundation
import SQLite
import SwiftUI
import UniformTypeIdentifiers

struct FileMetadata: Identifiable {
  // 必须实现 id，Table 才能识别选中行
  var id: String { "\(parent)/\(name)" }
  
  var parent: String
  var name: String
  var size: Int64
  var mtime: Int64 // 存储时通常是 Unix 时间戳
  var isDir: Bool
  
  // 格式化日期显示
  var modificationDate: String {
    
    let date = Date(timeIntervalSince1970: TimeInterval(mtime))
    
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    // 设置北京时区
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    
    let dateString = formatter.string(from: date)
    
    return dateString
  }
  
  // 格式化文件大小
  var sizeString: String {
    if isDir { return "--" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useAll]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: size)
  }
}

extension FileMetadata: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .item) { file in
      let url = URL(fileURLWithPath: file.parent + "/" + file.name)
      return SentTransferredFile(url)
    }
  }
}

enum SortOption {
  case modificationTime
  case name
  case size
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
  
  // 定义列
  private let id = Expression<Int64>("id")
  private let parent = Expression<String>("parent")
  private let name = Expression<String>("name")
  private let size = Expression<Int64>("size")
  private let mtime = Expression<Int64>("mtime")
  private let isDir = Expression<Bool>("is_dir")
  
  init(name: String) throws{
    
    do {
      let dbPath = getDatabaseURL(name: name).path(percentEncoded: false)
      db = try Connection(dbPath)
      try? db?.execute("PRAGMA mmap_size = 1073741824;")
      try? db?.execute("PRAGMA cache_size = -2000;")

      // 注册 REGEXP 自定义函数
      _ = try db?.createFunction("regexp", deterministic: true) { (pattern: String, value: String) -> Bool in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, range: range) != nil
      }
    } catch {
      print("数据库连接失败: \(error)")
      throw DatabaseError.connectionFailed(error.localizedDescription)
    }
  }
  func count() -> Int {
    guard let db = db else { return 0 }
    
    
    do {
      try db.execute("PRAGMA read_uncommitted = 1")
      let count = try db.scalar(files.count)
      try db.execute("PRAGMA read_uncommitted = 0")
      return count
    } catch {
      print("统计失败: \(error)")
      return 0
    }
  }
  func searchFiles(keywords: [String], sort: SortOption = .modificationTime, regex: Bool = false) -> [FileMetadata] {
    guard let db = db, !keywords.isEmpty else { return [] }
    var results: [FileMetadata] = []

    do {
      try db.execute("PRAGMA read_uncommitted = 1")

      if regex {
        results = searchWithRegex(db: db, pattern: keywords.joined(separator: " "), sort: sort)
      } else if let ftsResults = try? searchWithFTS(db: db, keywords: keywords, sort: sort) {
        results = ftsResults
      } else {
        results = searchWithLIKE(db: db, keywords: keywords, sort: sort)
      }

      try db.execute("PRAGMA read_uncommitted = 0")
    } catch {
      print("查询出错: \(error)")
    }
    return results
  }

  /// FTS5 全文索引查询
  private func searchWithFTS(db: Connection, keywords: [String], sort: SortOption) throws -> [FileMetadata] {
    // 每个关键词用双引号包裹作为短语匹配，空格分隔表示 AND
    let matchQuery = keywords.map { "\"\($0)\"" }.joined(separator: " ")
    let orderBy: String
    switch sort {
    case .modificationTime: orderBy = "f.mtime DESC"
    case .name: orderBy = "f.name ASC"
    case .size: orderBy = "f.size DESC"
    }

    let sql = """
      SELECT f.parent, f.name, f.size, f.mtime, f.is_dir
      FROM files_fts fts
      JOIN files f ON f.id = fts.rowid
      WHERE files_fts MATCH ?
      ORDER BY \(orderBy)
      LIMIT 500
      """

    var results: [FileMetadata] = []
    for row in try db.prepare(sql, [matchQuery]) {
      results.append(FileMetadata(
        parent: row[0] as! String,
        name: row[1] as! String,
        size: row[2] as! Int64,
        mtime: row[3] as! Int64,
        isDir: (row[4] as! Int64) != 0
      ))
    }
    return results
  }

  /// LIKE 兜底查询
  private func searchWithLIKE(db: Connection, keywords: [String], sort: SortOption) -> [FileMetadata] {
    var condition: SQLite.Expression<Bool> = name.like("%\(keywords[0])%")
    for kw in keywords.dropFirst() {
      condition = condition && name.like("%\(kw)%")
    }

    let order: [Expressible]
    switch sort {
    case .modificationTime: order = [Expression<String>("mtime").desc, Expression<String>("name").asc]
    case .name: order = [Expression<String>("name").asc]
    case .size: order = [Expression<String>("size").desc]
    }

    let query = files.filter(condition)
      .order(order)
      .limit(500)

    var results: [FileMetadata] = []
    guard let rows = try? db.prepare(query) else { return results }
    for row in rows {
      results.append(FileMetadata(
        parent: row[parent],
        name: row[name],
        size: row[size],
        mtime: row[mtime],
        isDir: row[isDir]
      ))
    }
    return results
  }

  /// 正则表达式查询
  private func searchWithRegex(db: Connection, pattern: String, sort: SortOption) -> [FileMetadata] {
    let orderBy: String
    switch sort {
    case .modificationTime: orderBy = "mtime DESC"
    case .name: orderBy = "name ASC"
    case .size: orderBy = "size DESC"
    }

    let sql = "SELECT parent, name, size, mtime, is_dir FROM files WHERE name REGEXP ? ORDER BY \(orderBy) LIMIT 500"

    var results: [FileMetadata] = []
    do {
      for row in try db.prepare(sql, [pattern]) {
        results.append(FileMetadata(
          parent: row[0] as! String,
          name: row[1] as! String,
          size: row[2] as! Int64,
          mtime: row[3] as! Int64,
          isDir: (row[4] as! Int64) != 0
        ))
      }
    } catch {
      print("正则查询出错: \(error)")
    }
    return results
  }

  // MARK: - 视图规则查询

  func searchWithRules(_ rules: [ViewRule], limit: Int = 10000) -> [FileMetadata] {
    guard let db = db, !rules.isEmpty else { return [] }
    var results: [FileMetadata] = []

    var whereClauses: [String] = []
    var params: [SQLite.Binding?] = []

    for rule in rules {
      switch rule {
      case .extensions(let exts):
        // (name LIKE '%.pdf' OR name LIKE '%.docx')
        let parts = exts.map { ext -> String in
          params.append(".\(ext)")
          return "name LIKE '%' || ?"
        }
        whereClauses.append("(\(parts.joined(separator: " OR ")))")

      case .filenameContains(let keywords):
        // (name LIKE '%keyword1%' AND name LIKE '%keyword2%')
        for kw in keywords {
          params.append(kw)
          whereClauses.append("name LIKE '%' || ? || '%'")
        }

      case .modifiedAfter(let date):
        params.append(Int64(date.timeIntervalSince1970))
        whereClauses.append("mtime > ?")

      case .customSQL(let sql):
        whereClauses.append("(\(sql))")
      }
    }

    let whereStr = whereClauses.joined(separator: " AND ")
    let sql = "SELECT parent, name, size, mtime, is_dir FROM files WHERE \(whereStr) ORDER BY mtime DESC LIMIT \(limit)"

    do {
      try db.execute("PRAGMA read_uncommitted = 1")
      for row in try db.prepare(sql, params) {
        results.append(FileMetadata(
          parent: row[0] as! String,
          name: row[1] as! String,
          size: row[2] as! Int64,
          mtime: row[3] as! Int64,
          isDir: (row[4] as! Int64) != 0
        ))
      }
      try db.execute("PRAGMA read_uncommitted = 0")
    } catch {
      print("视图查询出错: \(error)")
    }
    return results
  }
}
