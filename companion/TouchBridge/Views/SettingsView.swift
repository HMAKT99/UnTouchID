import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showUnpairConfirm = false

    var body: some View {
        List {
            if appState.unpairIncomplete {
                Section {
                    Label("Unpair incomplete", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Authentication is disabled. Retry Unpair below to finish removing the signing key.")
                        .font(.subheadline)
                }
            }

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

            if !appState.unpairIncomplete {
                Section {
                    TrustValueRow(title: "Device ID", value: appState.coordinator.pairedDeviceID)
                    if let fingerprint = appState.coordinator.pairedMacFingerprint {
                        TrustValueRow(title: "Mac fingerprint (SHA-256)", value: fingerprint)
                    }
                    if let fingerprint = appState.coordinator.signingFingerprint {
                        TrustValueRow(title: "iPhone signing fingerprint (SHA-256)", value: fingerprint)
                    }
                    if let publicKey = appState.coordinator.pairedSigningPublicKey {
                        DisclosureGroup("iPhone public key") {
                            TrustValueRow(title: "Public key (Base64)", value: publicKey.base64EncodedString())
                        }
                    }
                } header: {
                    Text("Trust verification")
                } footer: {
                    Text("Compare these values with the enrollment details on your Mac before trusting this device.")
                }
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
                Button(appState.unpairIncomplete ? "Retry Unpair" : "Unpair This Device", role: .destructive) {
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
            Text("This removes this iPhone’s signing key. You will need to pair again. Also remove this device from your Mac’s trusted devices.")
        }
        .alert("Could not finish unpairing", isPresented: Binding(
            get: { appState.unpairError != nil },
            set: { if !$0 { appState.unpairError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.unpairError = nil }
        } message: {
            Text(appState.unpairError ?? "")
        }
    }
}

private struct TrustValueRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
