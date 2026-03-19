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
  func upsert(items: [FileMetadata]) {
    guard let db = db else { return }
    
    do {
      // 1. 使用 run(transaction) 开启事务，极大提升批量写入速度
      try db.transaction {
        for item in items {
          // 2. 构造 replace 语句
          let statement = files.insert(or: .replace,
                                       self.parent <- item.parent,
                                       self.name <- item.name,
                                       self.size <- item.size,
                                       self.mtime <- item.mtime,
                                       self.isDir <- item.isDir
          )
          
          // 3. 执行单条插入
          try db.run(statement)
        }
      }
      log("✅ 成功批量更新 \(items.count) 条记录")
    } catch {
      log("❌ 批量写入数据库失败: \(error)")
    }
  }
  func delete(items: [FileMetadata]) {
    guard let db = db else { return }
    
    do {
      try db.transaction {
        for item in items {
          
          let parentPath = item.parent
          let fileName = item.name
          let path = (parentPath + "/" + fileName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
                                        .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
          // 1. 删除自身记录
          let target = files.filter(self.parent == parentPath && self.name == fileName)
          try db.run(target.delete())
          
          // 2. 删除所有子项（如果它是目录）
          // 逻辑：parent 以该 path 开头，例如 parent 等于 /Users/Desktop/MyFolder 或以 /Users/Desktop/MyFolder/ 开头
          let children = files.filter(self.parent.like("\(path)%"))
          try db.run(children.delete())
        }
      }
    } catch {
      log("❌ 批量删除失败: \(error)")
    }
  }
}
