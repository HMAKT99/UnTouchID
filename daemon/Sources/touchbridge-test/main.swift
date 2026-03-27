import ArgumentParser
import Foundation
import TouchBridgeCore
import TouchBridgeProtocol

@main
struct TouchBridgeTest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "touchbridge-test",
        abstract: "CLI test harness for TouchBridge challenge-response flow.",
        version: "0.1.0-dev",
        subcommands: [PairCommand.self, ChallengeCommand.self, ListDevicesCommand.self, ConfigCommand.self, LogsCommand.self]
    )
}

// MARK: - Pair

struct PairCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Generate pairing QR data and wait for a companion device."
    )

    @Option(name: .long, help: "Timeout in seconds to wait for pairing (default: 300).")
    var timeout: Int = 300

    func run() throws {
        let keychainStore = KeychainStore()
        let pairingManager = PairingManager(keychainStore: keychainStore)
        let coordinator = DaemonCoordinator(
            keychainStore: keychainStore,
            pairingManager: pairingManager
        )

        let semaphore = DispatchSemaphore(value: 0)
        var paired = false

        // Generate and display QR data
        let group = DispatchGroup()
        group.enter()

        Task {
            do {
                let qrData = try await pairingManager.generatePairingQRData()

                if let jsonString = String(data: qrData, encoding: .utf8) {
                    print("")
                    print("=== TouchBridge Pairing ===")
                    print("")
                    print("Scan this data with the TouchBridge companion app:")
                    print("")
                    print(jsonString)
                    print("")
                    print("Or use this base64-encoded payload for QR code generation:")
                    print(qrData.base64EncodedString())
                    print("")
                }
            } catch {
                print("Error generating pairing data: \(error)")
            }
            group.leave()
        }
        group.wait()

        // Set up pairing callback
        coordinator.onPairingComplete = { device in
            print("")
            print("Pairing successful!")
            print("  Device: \(device.displayName)")
            print("  ID:     \(device.deviceID)")
            print("  Paired: \(device.pairedAt)")
            print("")
            paired = true
            semaphore.signal()
        }

        // Start BLE advertising
        coordinator.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            coordinator.startAdvertising()
            print("Waiting for companion device to connect (timeout: \(self.timeout)s)...")
        }

        // Wait with timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
            if !paired {
                print("\nPairing timed out after \(self.timeout) seconds.")
                semaphore.signal()
            }
        }

        // Run the run loop on a background thread to handle BLE callbacks
        let thread = Thread {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: TimeInterval(self.timeout)))
        }
        thread.start()

        semaphore.wait()
        coordinator.stop()

        if !paired {
            throw ExitCode.failure
        }
    }
}

// MARK: - Challenge

struct ChallengeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "challenge",
        abstract: "Issue a challenge to a paired device and print the result."
    )

    @Option(name: .long, help: "Device ID of the paired companion.")
    var device: String

    @Option(name: .long, help: "Reason string shown on the companion device.")
    var reason: String = "touchbridge-test"

    @Option(name: .long, help: "Timeout in seconds to wait for response (default: 30).")
    var timeout: Int = 30

    func run() throws {
        let keychainStore = KeychainStore()

        // Verify the device is paired
        do {
            let pairedDevice = try keychainStore.retrievePairedDevice(deviceID: device)
            print("Challenging paired device: \(pairedDevice.displayName) (\(device))")
        } catch {
            print("Error: Device '\(device)' is not paired.")
            print("Run 'touchbridge-test pair' first.")
            throw ExitCode.failure
        }

        let coordinator = DaemonCoordinator(keychainStore: keychainStore)
        let semaphore = DispatchSemaphore(value: 0)
        var challengeResult: ChallengeResult?

        coordinator.onChallengeResult = { _, result, _ in
            challengeResult = result
            semaphore.signal()
        }

        coordinator.start()

        print("Starting BLE server, waiting for companion to connect...")

        // Wait for a central to connect and establish ECDH
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            coordinator.startAdvertising()
        }

        // Poll for a ready central
        var centralID: UUID?
        let pollDeadline = Date(timeIntervalSinceNow: TimeInterval(timeout))

        let thread = Thread {
            RunLoop.current.run(until: pollDeadline)
        }
        thread.start()

        while Date() < pollDeadline {
            if let first = coordinator.readyCentrals.first {
                centralID = first
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        guard let central = centralID else {
            print("\nNo companion device connected within \(timeout) seconds.")
            print("Make sure the TouchBridge app is running on your iPhone/iPad.")
            coordinator.stop()
            throw ExitCode.failure
        }

        print("Companion connected. Issuing challenge...")

        // Issue the challenge
        let group = DispatchGroup()
        group.enter()
        Task {
            let issued = await coordinator.issueChallenge(to: central, reason: reason)
            if issued == nil {
                print("Failed to issue challenge.")
                semaphore.signal()
            }
            group.leave()
        }
        group.wait()

        // Wait for response
        let waitResult = semaphore.wait(timeout: .now() + .seconds(timeout))

        coordinator.stop()

        if waitResult == .timedOut {
            print("\nFAILED_TIMEOUT: Companion did not respond within \(timeout) seconds.")
            throw ExitCode.failure
        }

        guard let result = challengeResult else {
            print("\nFAILED: No result received.")
            throw ExitCode.failure
        }

        switch result {
        case .verified:
            print("\nVERIFIED")
            print("Biometric authentication succeeded.")
        case .expired:
            print("\nFAILED_TIMEOUT")
            print("Challenge expired before response was received.")
            throw ExitCode.failure
        case .invalidSignature:
            print("\nFAILED_SIGNATURE")
            print("Signature verification failed.")
            throw ExitCode.failure
        case .replayDetected:
            print("\nFAILED_REPLAY")
            print("Replay attack detected — nonce was already used.")
            throw ExitCode.failure
        case .unknownChallenge:
            print("\nFAILED")
            print("Unknown challenge ID in response.")
            throw ExitCode.failure
        }
    }
}

// MARK: - List Devices

struct ListDevicesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-devices",
        abstract: "List all paired companion devices."
    )

    func run() throws {
        let store = KeychainStore()

        let devices = try store.listPairedDevices()

        if devices.isEmpty {
            print("No paired devices.")
            print("Run 'touchbridge-test pair' to pair a companion device.")
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        print("Paired devices (\(devices.count)):")
        print("")
        for device in devices {
            print("  \(device.displayName)")
            print("    ID:     \(device.deviceID)")
            print("    Paired: \(formatter.string(from: device.pairedAt))")
            print("    Key:    \(device.publicKey.prefix(8).map { String(format: "%02x", $0) }.joined())...")
            print("")
        }
    }
}

// MARK: - Config

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read and write TouchBridge policy configuration.",
        subcommands: [ConfigShow.self, ConfigSet.self, ConfigReset.self]
    )
}

struct ConfigShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show current policy configuration."
    )

    func run() throws {
        let engine = PolicyEngine()
        let policies = engine.allPolicies()

        print("TouchBridge Policy Configuration")
        print("  Auth timeout: \(engine.authTimeout())s")
        print("  RSSI threshold: \(engine.rssiThreshold()) dBm")
        print("")
        print("Surface Policies:")

        for (surface, policy) in policies.sorted(by: { $0.key < $1.key }) {
            let modeStr = policy.mode == .biometricRequired ? "biometric required" : "proximity session"
            var line = "  \(surface): \(modeStr)"
            if policy.mode == .proximitySession {
                let minutes = Int(policy.sessionTTLSeconds / 60)
                line += " (\(minutes) min)"
            }
            print(line)
        }
    }
}

struct ConfigSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a policy value."
    )

    @Option(name: .long, help: "Surface name (e.g., sudo, screensaver).")
    var surface: String?

    @Option(name: .long, help: "Auth mode: biometric_required or proximity_session.")
    var mode: String?

    @Option(name: .long, help: "Session TTL in minutes (for proximity_session mode).")
    var ttl: Int?

    @Option(name: .long, help: "Auth timeout in seconds.")
    var timeout: Int?

    @Option(name: .long, help: "RSSI threshold in dBm.")
    var rssi: Int?

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plistPath = "\(home)/Library/Application Support/TouchBridge/policy.plist"

        var dict = NSMutableDictionary(contentsOfFile: plistPath) ?? NSMutableDictionary()

        if let timeout { dict["AuthTimeoutSeconds"] = Double(timeout) }
        if let rssi { dict["RSSIThreshold"] = rssi }

        if let surface, let mode {
            var surfaces = dict["Surfaces"] as? [String: [String: Any]] ?? [:]
            var surfaceDict = surfaces[surface] ?? [:]
            surfaceDict["mode"] = mode
            if let ttl { surfaceDict["sessionTTLSeconds"] = Double(ttl * 60) }
            surfaces[surface] = surfaceDict
            dict["Surfaces"] = surfaces
        }

        let dir = (plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dict.write(toFile: plistPath, atomically: true)
        print("Policy saved.")
    }
}

struct ConfigReset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Reset policy to defaults."
    )

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plistPath = "\(home)/Library/Application Support/TouchBridge/policy.plist"
        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
        }
        print("Policy reset to defaults.")
    }
}

// MARK: - Logs

struct LogsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "View recent authentication events from the audit log."
    )

    @Option(name: .long, help: "Number of recent entries to show (default: 20).")
    var count: Int = 20

    @Option(name: .long, help: "Filter by surface (e.g., pam_sudo, pam_screensaver).")
    var surface: String?

    @Option(name: .long, help: "Filter by result (e.g., VERIFIED, FAILED_TIMEOUT).")
    var result: String?

    @Flag(name: .long, help: "Show entries as raw JSON.")
    var json: Bool = false

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let logDir = "\(home)/Library/Logs/TouchBridge"

        guard FileManager.default.fileExists(atPath: logDir) else {
            print("No log directory found at \(logDir)")
            return
        }

        // Find all log files sorted by date (newest first)
        let files = try FileManager.default.contentsOfDirectory(atPath: logDir)
            .filter { $0.hasSuffix(".ndjson") }
            .sorted()
            .reversed()

        var entries: [(String, AuditEntry)] = [] // (raw line, parsed entry)
        let decoder = JSONDecoder()

        for file in files {
            let path = "\(logDir)/\(file)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            for line in content.split(separator: "\n").reversed() {
                guard let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(AuditEntry.self, from: data) else { continue }

                // Apply filters
                if let surface, entry.surface != surface { continue }
                if let result, entry.result != result { continue }

                entries.append((String(line), entry))
                if entries.count >= count { break }
            }
            if entries.count >= count { break }
        }

        if entries.isEmpty {
            print("No matching log entries found.")
            return
        }

        if json {
            for (raw, _) in entries.reversed() {
                print(raw)
            }
            return
        }

        // Pretty print
        print("TouchBridge Audit Log (last \(entries.count) entries)")
        print(String(repeating: "─", count: 80))

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        for (_, entry) in entries.reversed() {
            let icon: String
            switch entry.result {
            case "VERIFIED": icon = "✓"
            case "ISSUED": icon = "→"
            default: icon = "✗"
            }

            let resultColor = entry.result == "VERIFIED" ? "" : ""
            var line = "\(icon) \(entry.ts)  \(entry.surface.padding(toLength: 18, withPad: " ", startingAt: 0))"
            line += " \(entry.result.padding(toLength: 18, withPad: " ", startingAt: 0))"

            if !entry.companionDevice.isEmpty {
                line += " [\(entry.companionDevice)]"
            }

            if let latency = entry.latencyMs {
                line += " \(latency)ms"
            }

            print(line)
        }

        print(String(repeating: "─", count: 80))
        print("\(entries.count) entries shown. Logs at: \(logDir)")
    }
}
