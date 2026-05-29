import AppKit
import Carbon

/// 全局快捷键管理器
/// 使用 Carbon HIToolbox 注册系统级热键
/// 默认: Cmd+Shift+Option+Space
class GlobalHotkeyManager {
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?

  // 快捷键: Cmd+Shift+Option+Space
  private let keyCode: UInt32 = UInt32(kVK_Space)
  private let modifiers: UInt32 = UInt32(cmdKey | shiftKey | optionKey)

  func register() {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )

    // 安装事件处理器
    InstallEventHandler(
      GetApplicationEventTarget(),
      { (_, event, _) -> OSStatus in
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID
        )

        if hotKeyID.id == 1 {
          DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first {
              window.makeKeyAndOrderFront(nil)
            }
          }
        }

        return noErr
      },
      1,
      &eventType,
      nil,
      &eventHandler
    )

    // 注册热键
    var hotKeyID = EventHotKeyID(signature: OSType(0x4551), id: 1) // "EQ" in hex
    RegisterEventHotKey(
      keyCode,
      modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
  }

  func unregister() {
    if let ref = hotKeyRef {
      UnregisterEventHotKey(ref)
      hotKeyRef = nil
    }
    if let ref = eventHandler {
      RemoveEventHandler(ref)
      eventHandler = nil
    }
  }
}
