import Cocoa
import Foundation

/// 日志写入器：常驻文件句柄 + 连续重复消息折叠
/// （此前"属性获取失败"曾连续刷出 38 万行、15MB 日志，每行还 open/close 一次文件）
enum LogWriter {
  static let queue = DispatchQueue(label: "com.easyq.agent.log")
  static let formatter = ISO8601DateFormatter()
  static var handle: FileHandle?
  static var lastMessage = ""
  static var repeatCount = 0

  static func write(_ line: String) {
    queue.sync {
      do {
        if handle == nil {
          let logsDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("easyq")
          let logFile = logsDir.appendingPathComponent("EasyQAgent.log")
          let fm = FileManager.default
          if !fm.fileExists(atPath: logsDir.path) {
            try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
          }
          if !fm.fileExists(atPath: logFile.path) {
            fm.createFile(atPath: logFile.path, contents: nil)
          }
          handle = try FileHandle(forWritingTo: logFile)
          handle?.seekToEndOfFile()
        }
        // 连续相同消息只计数，不逐行落盘
        if line == lastMessage {
          repeatCount += 1
          return
        }
        if repeatCount > 0 {
          let folded = "[\(formatter.string(from: Date()))] （上一条消息重复 ×\(repeatCount)）\n"
          let data = folded.data(using: .utf8) ?? Data()
          handle?.write(data)
          FileHandle.standardError.write(data)
          repeatCount = 0
        }
        lastMessage = line
        let data = (line + "\n").data(using: .utf8) ?? Data()
        handle?.write(data)
        FileHandle.standardError.write(data)
      } catch {
        handle = nil // 写失败下次重建句柄，不影响主功能
      }
    }
  }
}

func log(_ message: String) {
  let timestamp = ISO8601DateFormatter().string(from: Date())
  LogWriter.write("[\(timestamp)] \(message)")
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
  log("EasyQAgent 启动中...")
  if !checkFullDiskAccess() {
    log("缺少全盘访问权限，打开设置")
    openFDASettings()
  }
  IgnoreSet.loadConfig()
  log("初始化 DynamicDirTaskManager")
  let ddtm = DynamicDirTaskManager()
  log("调用 initTask")
  ddtm.initTask(NSHomeDirectory())
  DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("com.easyq.agent.forceScan"),
    object: nil,
    queue: .main
  ) { notification in
    let rebuild = notification.userInfo?["rebuild"] as? Bool ?? false
    if rebuild {
      log("🤖 Agent 收到指令：全量重建索引")
      ddtm.rebuildAll()
    } else if let path = notification.userInfo?["targetPath"] as? String {
      log("🤖 Agent 收到指令：立即扫描路径 \(path)")
      ddtm.forceRefresh(path)
    }
  }
}
RunLoop.main.run(until: Date.distantFuture)
