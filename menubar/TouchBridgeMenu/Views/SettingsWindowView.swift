import SwiftUI

struct SettingsWindowView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        TabView {
            GeneralSettingsView(state: state)
                .tabItem { Label("General", systemImage: "gear") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 450, height: 300)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Daemon") {
                    HStack {
                        Circle()
                            .fill(state.isDaemonRunning ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(state.isDaemonRunning ? "Running" : "Stopped")
                    }
                }

                LabeledContent("Connection") {
                    Text(state.isConnected ? "Phone connected" : "Not connected")
                }

                LabeledContent("Auth Count") {
                    Text("\(state.authCount)")
                }
            }

            Section("Actions") {
                Button("Uninstall TouchBridge...") {
                    let alert = NSAlert()
                    alert.messageText = "Uninstall TouchBridge?"
                    alert.informativeText = "This will remove the daemon, PAM module, and restore your original sudo config."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Uninstall")
                    alert.addButton(withTitle: "Cancel")

                    if alert.runModal() == .alertFirstButtonReturn {
                        runUninstall()
                    }
                }
                .foregroundStyle(.red)
            }
        }
        .padding()
    }

    private func runUninstall() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"/bin/bash /usr/local/share/touchbridge/uninstall.sh\" with administrator privileges"
        ]
        try? process.run()
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "touchid")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("TouchBridge")
                .font(.title2.bold())

            Text("Version 0.1.0-alpha")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Use your phone's fingerprint to\nauthenticate on any Mac.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()

            Link("GitHub", destination: URL(string: "https://github.com/HMAKT99/UnTouchID")!)
                .font(.caption)

            Text("MIT License")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}
