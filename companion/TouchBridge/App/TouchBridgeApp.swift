import SwiftUI

@main
struct TouchBridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            if appState.isPaired {
                MainTabView(appState: appState)
            } else {
                OnboardingView(appState: appState)
            }
        }
    }
}

/// Central app state observable by all views.
class AppState: ObservableObject {
    @Published var isPaired: Bool = false
    @Published var isConnected: Bool = false
    @Published var lastChallenge: String?
    @Published var statusMessage: String = "Not connected"
    @Published var challengeCount: Int = 0
    @Published var pendingChallenge: PendingChallenge?
    /// Set when the Secure Enclave signing key is invalidated due to a biometric enrollment change.
    /// Cleared when the user re-pairs or dismisses.
    @Published var keyInvalidated: Bool = false
    /// Set when the user explicitly cancelled or denied a Face ID / biometric prompt.
    /// Keeps the auth sheet open so the user sees feedback instead of a silent dismiss.
    @Published var challengeDenied: Bool = false

    let coordinator: CompanionCoordinator

    struct PendingChallenge: Identifiable {
        let id = UUID()
        let reason: String
        let macName: String
        let timestamp: Date
    }

    init() {
        let coordinator = CompanionCoordinator()
        self.coordinator = coordinator

        isPaired = UserDefaults.standard.string(forKey: "pairedMacID") != nil

        coordinator.onConnectionChanged = { [weak self] connected in
            DispatchQueue.main.async {
                self?.isConnected = connected
                self?.statusMessage = connected ? "Connected to Mac" : "Disconnected"
            }
        }

        coordinator.onChallengeReceived = { [weak self] info in
            DispatchQueue.main.async {
                let macName = UserDefaults.standard.string(forKey: "pairedMacName") ?? "Mac"
                self?.pendingChallenge = PendingChallenge(
                    reason: info,
                    macName: macName,
                    timestamp: Date()
                )
            }
        }

        coordinator.onChallengeResult = { [weak self] challengeID, success, error in
            DispatchQueue.main.async {
                self?.challengeCount += 1

                if case .keyInvalidated = error {
                    self?.pendingChallenge = nil
                    self?.keyInvalidated = true
                    self?.lastChallenge = "Key invalidated — re-pair required"
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                } else if case .biometricDenied = error {
                    // Keep the sheet open so the user sees the denial — they dismissed Face ID
                    // and would otherwise just see sudo silently ask for a password with no explanation.
                    self?.challengeDenied = true
                    self?.lastChallenge = "Denied"
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                } else {
                    self?.pendingChallenge = nil
                    self?.lastChallenge = success
                        ? "Approved (\(challengeID.prefix(8))...)"
                        : "Denied"
                    UINotificationFeedbackGenerator().notificationOccurred(success ? .success : .error)
                }
            }
        }

        coordinator.onPairingComplete = { [weak self] macID in
            DispatchQueue.main.async {
                self?.isPaired = true
                self?.statusMessage = "Paired with Mac"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }

        if isPaired {
            coordinator.startScanning()
        }
    }

    func unpair() {
        coordinator.disconnect()
        UserDefaults.standard.removeObject(forKey: "pairedMacID")
        UserDefaults.standard.removeObject(forKey: "pairedMacName")
        isPaired = false
        isConnected = false
        statusMessage = "Not connected"
        challengeCount = 0
        lastChallenge = nil
        keyInvalidated = false
        challengeDenied = false
    }
}

// MARK: - Main Tab View

struct MainTabView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(appState: appState)
            }
            .tabItem {
                Label("Home", systemImage: "touchid")
            }

            NavigationStack {
                ActivityView(appState: appState)
            }
            .tabItem {
                Label("Activity", systemImage: "clock.arrow.circlepath")
            }

            NavigationStack {
                SettingsView(appState: appState)
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .tint(.accentColor)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @State private var showPairing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Image(systemName: "touchid")
                    .font(.system(size: 80))
                    .foregroundColor(.accentColor)

                VStack(spacing: 12) {
                    Text("TouchBridge")
                        .font(.largeTitle.bold())

                    Text("Use Face ID on your iPhone to unlock\nyour Mac, authorize sudo, and more.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 16) {
                    OnboardingFeature(
                        icon: "lock.shield",
                        title: "Secure",
                        description: "Keys never leave the Secure Enclave"
                    )
                    OnboardingFeature(
                        icon: "wave.3.right",
                        title: "Wireless",
                        description: "Connects via Bluetooth — no cables"
                    )
                    OnboardingFeature(
                        icon: "key",
                        title: "No Passwords",
                        description: "Authenticate with just your face"
                    )
                }
                .padding(.horizontal, 32)

                Spacer()

                Button {
                    showPairing = true
                } label: {
                    Text("Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }
            .sheet(isPresented: $showPairing) {
                NavigationStack {
                    PairingView(appState: appState)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showPairing = false }
                            }
                        }
                }
            }
        }
    }
}

struct OnboardingFeature: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Home View

struct HomeView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Key-invalidated banner
                if appState.keyInvalidated {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Re-pair required")
                                .font(.subheadline.bold())
                            Text("Your Face ID / Touch ID enrollment changed. Open Settings to re-pair.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.yellow.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.yellow.opacity(0.4), lineWidth: 1)
                    )
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                // Status card
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(appState.isConnected ? Color.green.opacity(0.15) : Color.gray.opacity(0.1))
                            .frame(width: 120, height: 120)

                        Image(systemName: "touchid")
                            .font(.system(size: 56))
                            .foregroundStyle(appState.isConnected ? .green : .gray)
                    }

                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(appState.isConnected ? .green : .orange)
                                .frame(width: 8, height: 8)
                            Text(appState.statusMessage)
                                .font(.subheadline)
                        }

                        if let macName = UserDefaults.standard.string(forKey: "pairedMacName") {
                            Text(macName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 24)

                // Quick stats
                if appState.challengeCount > 0 {
                    HStack(spacing: 20) {
                        StatCard(
                            title: "Authenticated",
                            value: "\(appState.challengeCount)",
                            icon: "checkmark.shield"
                        )

                        if let last = appState.lastChallenge {
                            StatCard(
                                title: "Last Request",
                                value: last,
                                icon: "clock"
                            )
                        }
                    }
                    .padding(.horizontal)
                }

                // Actions
                if !appState.isConnected {
                    Button {
                        appState.coordinator.startScanning()
                        appState.statusMessage = "Scanning..."
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Label("Reconnect", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }

                Spacer(minLength: 40)
            }
        }
        .navigationTitle("TouchBridge")
        .sheet(item: $appState.pendingChallenge) { challenge in
            AuthRequestView(
                reason: challenge.reason,
                macName: challenge.macName,
                keyInvalidated: appState.keyInvalidated,
                wasDenied: appState.challengeDenied,
                onApprove: { appState.pendingChallenge = nil },
                onDeny: {
                    appState.challengeDenied = false
                    appState.pendingChallenge = nil
                }
            )
            .interactiveDismissDisabled()
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
            Text(value)
                .font(.headline)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Activity View

struct ActivityView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        List {
            if appState.challengeCount == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No Activity Yet")
                        .font(.title3.bold())
                    Text("Authentication requests will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
                .listRowBackground(Color.clear)
            } else {
                Section("Summary") {
                    LabeledContent("Total Requests", value: "\(appState.challengeCount)")
                    if let last = appState.lastChallenge {
                        LabeledContent("Last Result", value: last)
                    }
                }
            }
        }
        .navigationTitle("Activity")
    }
}
