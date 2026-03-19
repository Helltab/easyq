import Cocoa

print("Agent init")
let app = NSApplication.shared
let delegate = LaunchOnAppOpenAgent()
app.delegate = delegate
app.run()
