import Cocoa

//@main
final class LaunchOnAppOpenAgent: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🎧 MusicWatcherAgent launched")
        AppMonitor.start()
    }
}
