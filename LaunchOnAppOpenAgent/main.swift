import Cocoa

let app = NSApplication.shared
let delegate = LaunchOnAppOpenAgent()
app.delegate = delegate
app.run()
