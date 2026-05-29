import SwiftUI
import ServiceManagement

@main
struct EasyQApp: App {
  init() {
    startAgentIfNeeded()
  }

  var body: some Scene {
    WindowGroup {
      FileSearchView()
    }
    .commands {
      IndexMenuCommands()
      ViewMenuCommands()
    }
  }

  private func startAgentIfNeeded() {
    guard #available(macOS 13.0, *) else { return }

    let agent = SMAppService.loginItem(
      identifier: "icu.helltab.com.EasyQ.agent"
    )

    do {
      try agent.register()

      let running = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == "icu.helltab.com.EasyQ.agent"
      }

      if !running {
        if let url = Bundle.main.bundleURL
          .appendingPathComponent("Contents/Library/LoginItems/EasyQAgent.app", isDirectory: true) as URL? {
          NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
      }
    } catch {
      print("Failed to register agent login item:", error)
    }
  }
}

// MARK: - 索引菜单

struct IndexMenuCommands: Commands {
  @FocusedValue(\.indexCount) var indexCount
  @FocusedValue(\.selectFolder) var selectFolder
  @FocusedValue(\.rebuildIndex) var rebuildIndex

  var body: some Commands {
    CommandMenu("索引") {
      if let count = indexCount {
        Text("已索引 \(count) 个文件")
          .foregroundColor(.secondary)
      }
      Divider()
      Button("强制刷新...") {
        selectFolder?()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(selectFolder == nil)

      Button("重建索引...") {
        rebuildIndex?()
      }
      .keyboardShortcut("r", modifiers: [.command, .option, .shift])
      .disabled(rebuildIndex == nil)
    }
  }
}

// MARK: - 视图菜单

struct ViewMenuCommands: Commands {
  @FocusedValue(\.rebuildViews) var rebuildViews

  var body: some Commands {
    CommandMenu("视图") {
      Button("重建所有视图") {
        rebuildViews?()
      }
      .keyboardShortcut("b", modifiers: [.command, .shift])
      .disabled(rebuildViews == nil)
    }
  }
}
