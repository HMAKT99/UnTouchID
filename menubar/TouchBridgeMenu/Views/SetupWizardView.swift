import SwiftUI

struct SetupWizardView: View {
    @ObservedObject var state: MenuBarState
    @State private var currentStep = 0
    @State private var installOutput = ""
    @State private var isInstalling = false
    @State private var installComplete = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "touchid")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                Text("TouchBridge Setup")
                    .font(.title.bold())
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            // Step indicator
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 24)

            // Content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: pairStep
                case 2: installStep
                case 3: doneStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)

            Spacer()

            // Navigation
            HStack {
                if currentStep > 0 && currentStep < 3 {
                    Button("Back") { currentStep -= 1 }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if currentStep < 3 {
                    Button(currentStep == 0 ? "Get Started" : "Next") {
                        if currentStep == 2 && !installComplete {
                            runInstall()
                        } else {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentStep == 2 && isInstalling)
                } else {
                    Button("Done") {
                        NSApplication.shared.keyWindow?.close()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Text("Use your phone's fingerprint to\nauthenticate on your Mac.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "lock.shield", text: "Authenticate sudo with Face ID or fingerprint")
                FeatureRow(icon: "display", text: "Unlock screensaver without typing password")
                FeatureRow(icon: "iphone", text: "Uses the protocol v2 iPhone companion")
                FeatureRow(icon: "key", text: "No $199 Magic Keyboard needed")
            }
        }
    }

    private var installStep: some View {
        VStack(spacing: 16) {
            if isInstalling {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding()
                Text("Activating authentication...")
                    .font(.headline)
                Text("Root key enrollment must already be complete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if installComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Activation Command Completed")
                    .font(.headline)
                Text("Verify real phone approval and password fallback next.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                Text("Activate TouchBridge")
                    .font(.headline)
                Text("Install the reviewed v2 package and enroll verified keys first.\nAdministrator authentication is required to activate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if !installOutput.isEmpty {
                    Text(installOutput).font(.caption).foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Activation prerequisites:")
                        .font(.caption.bold())
                    Text("• Reviewed v2 installation")
                        .font(.caption)
                    Text("• Protected PAM verifier")
                        .font(.caption)
                    Text("• Verified phone and Mac fingerprints")
                        .font(.caption)
                    Text("• Explicit root key enrollment")
                        .font(.caption)
                }
                .padding()
                .background(.regularMaterial)
                .cornerRadius(8)
            }
        }
    }

    private var pairStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 48))
            Text("Pair and Verify Your iPhone").font(.headline)
            Text("Install the signed iPhone companion, scan the v2 QR, compare both fingerprints, then explicitly enroll the verified keys before activation.")
                .font(.caption).multilineTextAlignment(.center)
            PairOption(icon: "iphone", title: "Pair iPhone", desc: "QR-pinned encrypted BLE", command: "touchbridge-test pair")
            PairOption(icon: "key", title: "Export Public Metadata", desc: "Compare with trusted phone Settings", command: "touchbridge-test export-pam-trust")
            Text("Use the migration guide from this reviewed v2 source checkout; published v1 setup instructions do not apply.").font(.caption)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Activation Requested")
                .font(.headline)

            Text("Confirm actual phone approval, denial and password fallback.\nA completed command is not device acceptance.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Image(systemName: "terminal")
                    .foregroundColor(.accentColor)
                Text("sudo echo 'TouchBridge works!'")
                    .font(.system(.caption, design: .monospaced))
            }
            .padding()
            .background(.regularMaterial)
            .cornerRadius(8)
        }
    }

    // MARK: - Actions

    private func runInstall() {
        let command: String
        do {
            command = try ProtectedInstallation.command(for: .activate)
        } catch {
            installOutput = error.localizedDescription
            return
        }
        isInstalling = true
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"" + command + "\" with administrator privileges"]
            let completed: Bool
            do {
                try process.run()
                process.waitUntilExit()
                completed = process.terminationStatus == 0
            } catch {
                completed = false
            }
            DispatchQueue.main.async {
                isInstalling = false
                installComplete = completed
                installOutput = completed ? "" : "Activation was cancelled or rejected. Complete verified key enrollment before retrying."
                state.checkInstallation()
                if completed { currentStep = 3 }
            }
        }
    }

}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }
}

struct PairOption: View {
    let icon: String
    let title: String
    let desc: String
    let command: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(.regularMaterial)
        .cornerRadius(8)
    }
}
