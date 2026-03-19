import Foundation

class DynamicDirTaskManager: ScannerDelegate {
  
  
  private var scanner = FSScanner()
  
  
  private var fileDB = FileDatabase(path: "files.db", )
  
  // 实现协议方法
  func scannerDidFindFolder(_ path: String) {
    
    self.addTask(path)
  }
  
  func scannerDidBatchFiles(_ files: [FileMetadata]) {
    fileDB.saveFiles(files)
  }
  
  func scannerDidFinishProcessing(_ path: String, success: Bool) {
    print("任务处理完毕: \(path)")
  }
  
  
  private var continuation: AsyncStream<String>.Continuation?
  private lazy var taskStream: AsyncStream<String> = {
    AsyncStream { continuation in
      self.continuation = continuation
    }
  }()
  
  init() {
    
    
    // 启动后台消费者，监听任务流
    Task {
      for await path in taskStream {
        await process(path)
      }
    }
    scanner.delegate = self
    
  }
  
  // 扫描器：动态调用此方法添加任务
  func addTask(_ path: String) {
    continuation?.yield(path)
  }
  
  private func process(_ path: String) async {
    print("正在处理动态文件夹: \(path)")
    scanner.scanDirectory(path)
  }
}
