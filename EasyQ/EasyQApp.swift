import SwiftUI
import ServiceManagement

@main
struct EasyQApp: App {
  init() {
    // App 启动时立即注册并启动 agent
    startAgentIfNeeded()
  }
  var body: some Scene {
    WindowGroup {
      FileSearchView()
    }
  }

  private func startAgentIfNeeded() {
    guard #available(macOS 13.0, *) else { return }
    
    let agent = SMAppService.loginItem(
      identifier: "icu.helltab.com.EasyQ.agent"
    )
    
    do {
     
      try agent.register()
      
      // 检查 agent 是否已经运行
      let running = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == "icu.helltab.com.EasyQ.agent"
      }
      
      if !running {
        // 启动 agent
        if let url = Bundle.main.bundleURL
          .appendingPathComponent("Contents/Library/LoginItems/EasyQAgent.app", isDirectory: true) as URL? {
          NSWorkspace.shared.openApplication(at: url, configuration: .init())
          print("Agent started automatically")
        }
      } else {
        print("Agent already running, skip starting")
      }
      
    } catch {
      print("Failed to register agent login item:", error)
    }
  }
}
