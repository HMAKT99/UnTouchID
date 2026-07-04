import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showUnpairConfirm = false

    var body: some View {
        List {
            if appState.keyInvalidated {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Re-pair required")
                                .font(.subheadline.bold())
                            Text("Your Face ID / Touch ID enrollment changed since pairing. Unpair and pair again to restore authentication.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

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
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")

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
