import Foundation
import SQLite

struct FileMetadata {
  init() {
    self.parent = ""
    self.name = ""
    self.size = 0
    self.mtime = 0
    self.isDir = false
  }
  init(parent: String, name: String, size: Int64, mtime: Int, isDir: Bool) {
    self.parent = parent
    self.name = name
    self.size = size
    self.mtime = mtime
    self.isDir = isDir
  }
  var parent: String
  var name: String
  var size: Int64
  var mtime: Int
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
  
  // 定义列
  private let id = Expression<Int64>("id")
  private let parent = Expression<String>("parent")
  private let name = Expression<String>("name")
  private let size = Expression<Int64>("size")
  private let mtime = Expression<Int>("mtime")
  private let isDir = Expression<Bool>("is_dir")
  
  init(name: String) throws{
    
    do {
      let dbPath = getDatabaseURL(name: name).path(percentEncoded: false)
      log("数据库位于: \(dbPath)")
      db = try Connection(dbPath)
      try createTableAndIndices()
    } catch {
      log("数据库连接失败: \(error)")
      throw DatabaseError.connectionFailed(error.localizedDescription)
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
    
    log("数据库 DDL 执行成功")
  }
  
  func saveFiles(_ fileList: [FileMetadata]) {
    guard let db = db else { return }
    
    do {
      // 关键点：开启事务
      try db.transaction {
        for file in fileList {
          try db.run(files.insert(
            or: .replace, // 冲突时替换，对应你的 UNIQUE(parent, name)
            self.parent <- file.parent,
            self.name <- file.name,
            self.size <- file.size,
            self.mtime <- file.mtime,
            self.isDir <- file.isDir
          ))
        }
      }
      log("成功入库 \(fileList.count) 条记录")
    } catch {
      log("批量插入失败: \(error)")
    }
  }
}
