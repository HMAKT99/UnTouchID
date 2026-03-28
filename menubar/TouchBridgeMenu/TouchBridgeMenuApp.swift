import SwiftUI

@main
struct TouchBridgeMenuApp: App {
    @StateObject private var appState = MenuBarState()

    var body: some Scene {
        // Menu bar icon
        MenuBarExtra {
            MenuBarView(state: appState)
        } label: {
            Image(systemName: appState.isConnected ? "touchid" : "touchid")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(appState.isConnected ? .green : .secondary)
        }
        .menuBarExtraStyle(.window)

        // Setup wizard window (shown on first launch)
        WindowGroup("TouchBridge Setup", id: "setup") {
            SetupWizardView(state: appState)
                .frame(width: 500, height: 600)
        }
        .windowResizability(.contentSize)

        // Settings window
        Settings {
            SettingsWindowView(state: appState)
        }
    }
}
