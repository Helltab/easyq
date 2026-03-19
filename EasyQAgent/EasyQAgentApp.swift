import Cocoa


final class EasyQAgentApp: NSObject, NSApplicationDelegate {

  nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
      print("Agent start ...")
      NSLog("🎧 MusicWatcherAgent launched")
    }
}
