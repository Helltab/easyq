import Foundation

class DynamicDirTaskManager: ScannerDelegate {


  private var scanner = FSScanner()


  private var fileDB: FileDatabase?
  private var monitor: FileSyncManager?
  private var homePath: String = ""
  private var pendingTasks: Int = 0
  private var scannedCount: Int = 0
  private var taskEpoch: Int = 0
  private var needsFTSRebuild: Bool = false
  
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
  
  
  private var continuation: AsyncStream<(String, Int)>.Continuation?
  private lazy var taskStream: AsyncStream<(String, Int)> = {
    AsyncStream { continuation in
      self.continuation = continuation
    }
  }()
  
  init() {
    do {
      self.fileDB = try FileDatabase(name: "easyqfiles.db", )
      
      // 启动后台消费者，监听任务流
      Task {
        for await (path, epoch) in taskStream {
          if epoch != self.taskEpoch {
            // 旧批次的残留任务，跳过但正确计数
            self.pendingTasks -= 1
            continue
          }
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
    self.homePath = path
    self.scanner.homeDepth = path.components(separatedBy: "/").count
    let has = self.fileDB?.hasFiles()
    if !(has ?? false) {
      addTask(path)
    }
  }
  // 扫描器：动态调用此方法添加任务
  func addTask(_ path: String) {
    pendingTasks += 1
    continuation?.yield((path, taskEpoch))
  }
  func forceRefresh(_ path: String) {
    var file = FileMetadata()
    file.parent = path
    file.name = ""
    self.fileDB?.delete(items: [file])
    addTask(path)
  }

  /// 清空数据库并重新全量扫描
  func rebuildAll() {
    log("开始全量重建索引")
    taskEpoch += 1
    needsFTSRebuild = true
    self.scannedCount = 0
    self.fileDB?.clearAll()
    addTask(homePath)
  }
  
  
  private func process(_ path: String) async {
    log("正在处理动态文件夹: \(path)")

    let files = scanner.scanDirectory(path)
    fileDB?.saveFiles(files)
    scannedCount += files.count
    pendingTasks -= 1

    // 通知 GUI 当前扫描进度（扫描完成后发送，确保 scannedCount 已更新）
    DispatchQueue.main.async {
      DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("com.easyq.agent.scanProgress"),
        object: nil,
        userInfo: ["currentPath": path, "pendingTasks": self.pendingTasks, "scannedCount": self.scannedCount],
        deliverImmediately: true
      )
    }

    // 所有任务完成后：通知 GUI（仅全量重建时重建 FTS5）
    if pendingTasks == 0 {
      if needsFTSRebuild {
        fileDB?.rebuildFTS()
        needsFTSRebuild = false
      }
      DispatchQueue.main.async {
        DistributedNotificationCenter.default().postNotificationName(
          NSNotification.Name("com.easyq.agent.scanComplete"),
          object: nil,
          deliverImmediately: true
        )
      }
    }
  }
}
