import SwiftUI
import ServiceManagement

struct ContentView: View {

    @State private var enabled = false

    var body: some View {
        Toggle("Launch when Music app opens", isOn: $enabled)
            .onChange(of: enabled) { value in
                toggleAgent(value)
            }
            .padding()
    }

    private func toggleAgent(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }

        let agent = SMAppService.loginItem(
            identifier: "com.duhnnie.LaunchOnAppOpen.agent"
        )
        
        do {
            enabled ? try agent.register() : try agent.unregister()
        } catch {
            print("Login item error:", error)
        }
    }
}
