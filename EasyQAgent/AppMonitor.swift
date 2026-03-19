import Cocoa

enum AppMonitor {

    static func start() {
        
        
        let workspace = NSWorkspace.shared
        print("Agent start")
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleID = app.bundleIdentifier
            else { return }

            if bundleID == "com.apple.Music" {
                launchMainApp()
            }
        }

        RunLoop.main.run()
    }

    private static func launchMainApp() {
        let runningApps = NSWorkspace.shared.runningApplications
        let isRunning = runningApps.contains { app in
            return app.bundleIdentifier == "icu.helltab.com.EasyIndex"
        }
        
        if !isRunning {
            var path = Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path.absoluteString),
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil)
        }
        
    }
}
