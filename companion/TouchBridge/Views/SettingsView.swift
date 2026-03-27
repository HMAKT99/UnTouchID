import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showUnpairConfirm = false

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.isConnected ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(appState.isConnected ? "Connected" : "Disconnected")
                    }
                }

                if let macName = UserDefaults.standard.string(forKey: "pairedMacName") {
                    LabeledContent("Paired Mac", value: macName)
                }

                LabeledContent("Auth Requests", value: "\(appState.challengeCount)")
            }

            Section("Device") {
                LabeledContent("Biometric") {
                    Text(appState.coordinator.localAuth.isBiometricAvailable() ? "Available" : "Not Available")
                        .foregroundStyle(appState.coordinator.localAuth.isBiometricAvailable() ? .green : .red)
                }

                LabeledContent("BLE", value: appState.coordinator.isConnected ? "Active" : "Idle")
            }

            Section("About") {
                LabeledContent("Version", value: "0.1.0-alpha")
                LabeledContent("Build", value: "1")

                Link(destination: URL(string: "https://github.com/HMAKT99/UnTouchID")!) {
                    HStack {
                        Text("Source Code")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Unpair This Device", role: .destructive) {
                    showUnpairConfirm = true
                }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Unpair from Mac?",
            isPresented: $showUnpairConfirm,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                appState.unpair()
            }
        } message: {
            Text("You will need to pair again to use TouchBridge.")
        }
    }
}
