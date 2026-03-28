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
                case 1: installStep
                case 2: pairStep
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
                        if currentStep == 1 && !installComplete {
                            runInstall()
                        } else {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentStep == 1 && isInstalling)
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
                FeatureRow(icon: "iphone", text: "Works with iPhone, Android, or any browser")
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
                Text("Installing TouchBridge...")
                    .font(.headline)
                Text("This will ask for your admin password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if installComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Installation Complete")
                    .font(.headline)
                Text("Daemon, PAM module, and LaunchAgent installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                Text("Install TouchBridge")
                    .font(.headline)
                Text("This will install the daemon and PAM module.\nYour admin password will be required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 4) {
                    Text("What gets installed:")
                        .font(.caption.bold())
                    Text("• touchbridged daemon → /usr/local/bin/")
                        .font(.caption)
                    Text("• PAM module → /usr/local/lib/pam/")
                        .font(.caption)
                    Text("• LaunchAgent (auto-start on login)")
                        .font(.caption)
                    Text("• sudo config patched (with backup)")
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
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Pair Your Phone")
                .font(.headline)

            Text("Choose how to authenticate:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                PairOption(
                    icon: "globe",
                    title: "Any Phone (Browser)",
                    desc: "No app needed — open a URL on any phone",
                    command: "touchbridged serve --web"
                )
                PairOption(
                    icon: "iphone",
                    title: "iPhone (Face ID)",
                    desc: "Build iOS app in Xcode, pair via BLE",
                    command: "touchbridge-test pair"
                )
                PairOption(
                    icon: "display",
                    title: "Simulator (Testing)",
                    desc: "No phone needed — auto-approves",
                    command: "touchbridged serve --simulator"
                )
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.headline)

            Text("TouchBridge is running in your menu bar.\nTry it out:")
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
        isInstalling = true
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e",
                "do shell script \"/bin/bash \\\"$(dirname $(dirname $(dirname \\\"\\(Bundle.main.bundlePath)\\\")))/scripts/install.sh\\\"\" with administrator privileges"
            ]
            try? process.run()
            process.waitUntilExit()

            DispatchQueue.main.async {
                isInstalling = false
                installComplete = process.terminationStatus == 0
                state.checkInstallation()
                if installComplete { currentStep = 2 }
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
