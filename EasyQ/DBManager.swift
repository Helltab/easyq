import Foundation
import SQLite

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
  func searchFiles(keyword: String) -> [FileMetadata] {
    guard let db = db else { return [] }
    var results: [FileMetadata] = []
    
    do {
      try db.execute("PRAGMA read_uncommitted = 1")
      
      let nameSort = Expression<String>("name")
      let mtimeSort = Expression<String>("mtime")
      // 构造查询语句：WHERE name LIKE '%keyword%'
      let query = files.filter(name.like("%\(keyword)%"))
        .order([mtimeSort.desc, nameSort.asc])
        .limit(500)
      
      for row in try db.prepare(query) {
        results.append(FileMetadata(
          parent: row[parent],
          name: row[name],
          size: row[size],
          mtime: row[mtime],
          isDir: row[isDir]
        ))
      }
      try db.execute("PRAGMA read_uncommitted = 0")
    } catch {
      print("查询出错: \(error)")
    }
    return results
  }
  
  
}
