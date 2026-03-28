import Foundation
import SwiftUI

class MenuBarState: ObservableObject {
    @Published var isInstalled: Bool = false
    @Published var isDaemonRunning: Bool = false
    @Published var isConnected: Bool = false
    @Published var pairedDeviceName: String?
    @Published var recentEvents: [AuthEvent] = []
    @Published var authCount: Int = 0

    struct AuthEvent: Identifiable, Codable {
        let id = UUID()
        let ts: String
        let surface: String
        let result: String
        let companionDevice: String

        enum CodingKeys: String, CodingKey {
            case ts, surface, result
            case companionDevice = "companion_device"
        }
    }

    private var refreshTimer: Timer?

    init() {
        checkInstallation()
        startRefreshing()
    }

    func checkInstallation() {
        isInstalled = FileManager.default.fileExists(atPath: "/usr/local/bin/touchbridged")
            && FileManager.default.fileExists(atPath: "/usr/local/lib/pam/pam_touchbridge.so")

        let socketPath = "\(NSHomeDirectory())/Library/Application Support/TouchBridge/daemon.sock"
        isDaemonRunning = FileManager.default.fileExists(atPath: socketPath)
    }

    func loadRecentEvents() {
        let logDir = "\(NSHomeDirectory())/Library/Logs/TouchBridge"
        let fm = FileManager.default

        guard fm.fileExists(atPath: logDir),
              let files = try? fm.contentsOfDirectory(atPath: logDir)
                .filter({ $0.hasSuffix(".ndjson") })
                .sorted()
                .reversed() else { return }

        var events: [AuthEvent] = []
        let decoder = JSONDecoder()

        for file in files {
            let path = "\(logDir)/\(file)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            for line in content.split(separator: "\n").reversed() {
                guard let data = line.data(using: .utf8),
                      let event = try? decoder.decode(AuthEvent.self, from: data) else { continue }
                events.append(event)
                if events.count >= 10 { break }
            }
            if events.count >= 10 { break }
        }

        DispatchQueue.main.async {
            self.recentEvents = events
            self.authCount = events.filter { $0.result == "VERIFIED" }.count
        }
    }

    func startRefreshing() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkInstallation()
            self?.loadRecentEvents()
        }
        loadRecentEvents()
    }

    func openSetupWizard() {
        if let url = URL(string: "touchbridge://setup") {
            NSWorkspace.shared.open(url)
        }
    }
}
