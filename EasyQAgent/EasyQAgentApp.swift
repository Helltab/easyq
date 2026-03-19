import Cocoa

//@main
final class EasyQAgentApp: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🎧 MusicWatcherAgent launched")
      print("Agent start ...")
        AppMonitor.start()
    }
}
