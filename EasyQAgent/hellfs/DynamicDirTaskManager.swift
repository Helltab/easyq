import Foundation

class DynamicDirTaskManager: ScannerDelegate {
  
  
  private var scanner = FSScanner()
  
  
  private var fileDB: FileDatabase?
  private var monitor: FileSyncManager?
  
  // 实现协议方法
  func scannerDidFindFolder(_ path: String) {
    
    self.addTask(path)
  }
  
  func scannerDidBatchFiles(_ files: [FileMetadata]) {
    fileDB?.saveFiles(files)
  }
  
  func scannerDidFinishProcessing(_ path: String, success: Bool) {
    log("任务处理完毕: \(path)")
  }
  
  
  private var continuation: AsyncStream<String>.Continuation?
  private lazy var taskStream: AsyncStream<String> = {
    AsyncStream { continuation in
      self.continuation = continuation
    }
  }()
  
  init() {
    do {
      self.fileDB = try FileDatabase(name: "easyqfiles.db", )
      
      // 启动后台消费者，监听任务流
      Task {
        for await path in taskStream {
          await process(path)
        }
        
      }
      Task {
        self.startWatching()
      }
      scanner.delegate = self
      
    }catch {
      log("初始化失败: \(error)")
      self.fileDB = nil
    }
    
  }
  func startWatching() {
    // 监听用户文稿目录
    //let docsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
//    let downloadPath = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
  
    let homePath = NSHomeDirectory()
    log("开始监听\(homePath)")
    monitor = FileSyncManager()
    monitor?.delegate = self
    monitor?.startMonitoring(paths: [homePath], )
  }
  func syncDelete(_ files: [FileMetadata]) {
    self.fileDB?.delete(items: files)
  }
  func syncUpdate(_ files: [FileMetadata]) {
    self.fileDB?.upsert(items:  files)
  }
  func initTask(_ path: String) {
    let has = self.fileDB?.hasFiles()
    if !(has ?? false) {
      addTask(path)
    }
  }
  // 扫描器：动态调用此方法添加任务
  func addTask(_ path: String) {
    continuation?.yield(path)
  }
  func forceRefresh(_ path: String) {
    var file = FileMetadata()
    file.parent = path
    file.name = ""
    self.fileDB?.delete(items: [file])
    addTask(path)
  }
  
  
  private func process(_ path: String) async {
    log("正在处理动态文件夹: \(path)")
    let files = scanner.scanDirectory(path)
    fileDB?.saveFiles(files)
  }
}
