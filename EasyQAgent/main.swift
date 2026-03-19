import Cocoa
import Foundation
func log(_ message: String) {
  let fileManager = FileManager.default
  let logsDir = URL(fileURLWithPath: NSTemporaryDirectory() + "/easyq")
  let logFile = logsDir.appendingPathComponent("EasyQAgent.log")
  
  let timestamp = ISO8601DateFormatter().string(from: Date())
  let fullMessage = "[\(timestamp)] \(message)\n"
  
  // 确保 Logs 目录存在
  if !fileManager.fileExists(atPath: logsDir.path) {
    try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
  }
  
  // 追加写入文件
  if let handle = try? FileHandle(forWritingTo: logFile) {
    handle.seekToEndOfFile()
    if let data = fullMessage.data(using: .utf8) {
      handle.write(data)
    }
    handle.closeFile()
  } else {
    // 文件不存在就创建
    try? fullMessage.write(to: logFile, atomically: true, encoding: .utf8)
  }
}


// 调用示例
//readDirNamesOnlyNameAttr(dirName: "/Users/helltab/Downloads")
//scanDirectory(_: "/Users/helltab/Downloads")
//
func checkFullDiskAccess() -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let path = home.appendingPathComponent("Library/Safari/Bookmarks.plist").path
    return FileManager.default.isReadableFile(atPath: path)
}
func openFDASettings() {
    // 这是一个特殊的 URL 协议，可以直接定位到“全盘访问权限”页面
    let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    if let url = URL(string: urlString) {
        NSWorkspace.shared.open(url)
    }
}

Task {
  if !checkFullDiskAccess() {
    openFDASettings()
  }
  let ddtm = DynamicDirTaskManager()
  ddtm.initTask(NSHomeDirectory())
  DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("com.easyq.agent.forceScan"),
    object: nil,
    queue: .main
  ) { notification in
    if let path = notification.userInfo?["targetPath"] as? String {
      log("🤖 Agent 收到指令：立即扫描路径 \(path)")
      ddtm.forceRefresh(path)
    }
    
  }
}
RunLoop.main.run(until: Date.distantFuture)
