import ArgumentParser
import Foundation
import TouchBridgeCore

@main
struct TouchBridgeDaemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "touchbridged",
        abstract: "TouchBridge daemon — delegates macOS auth to a companion iOS device.",
        version: "0.1.0-dev",
        subcommands: [Serve.self]
    )
}

struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the TouchBridge daemon."
    )

    @Option(name: .long, help: "RSSI proximity threshold in dBm (default: -75).")
    var rssiThreshold: Int = -75

    @Flag(name: .long, help: "Run in simulator mode — no iPhone needed. Auto-approves all auth requests using software keys.")
    var simulator: Bool = false

    @Flag(name: .long, help: "Interactive simulator — prompts in terminal for approve/deny. Implies --simulator.")
    var interactive: Bool = false

    @Flag(name: .long, help: "Web companion mode — authenticate from any phone via browser. No app install needed.")
    var web: Bool = false

    @Option(name: .long, help: "Port for web companion server (default: 7070).")
    var webPort: UInt16 = 7070

    @Flag(name: .long, help: "Enable proximity auto-lock — lock Mac when companion disconnects.")
    var autoLock: Bool = false

    func run() throws {
        if simulator || interactive {
            try runSimulatorMode()
        } else if web {
            try runWebMode()
        } else {
            try runNormalMode()
        }
    }

    private func runSimulatorMode() throws {
        let mode: SimulatorAuthHandler.Mode = interactive ? .interactive : .autoApprove

        print("touchbridged v0.1.0-dev (SIMULATOR MODE: \(mode.rawValue))")
        print("")
        print("  No iPhone required. Auth requests will be handled locally.")
        print("  This mode is for testing only — not for production use.")
        print("")

        let policyEngine = PolicyEngine()
        let simulatorHandler = SimulatorAuthHandler(mode: mode)

        let socketServer = SocketServer(authHandler: simulatorHandler, policyEngine: policyEngine)
        do {
            try socketServer.start()
            print("  Socket: \(socketServer.path)")
        } catch {
            print("Error: Failed to start socket server: \(error)")
            Darwin.exit(1)
        }

        print("  Ready. Waiting for auth requests...")
        print("")

        setupShutdownHandler {
            print("\nShutting down simulator...")
            socketServer.stop()
        }

        RunLoop.current.run()
    }

    private func runWebMode() throws {
        print("touchbridged v0.1.0-dev (WEB COMPANION MODE)")
        print("")
        print("  No iPhone app required.")
        print("  Auth requests will show a URL — open it on any phone to approve.")
        print("")

        let policyEngine = PolicyEngine()
        let webCompanion = WebCompanion(port: webPort)
        let webHandler = WebCompanionAuthHandler(webCompanion: webCompanion)

        do {
            try webCompanion.start()
        } catch {
            print("Error: Failed to start web companion on port \(webPort): \(error)")
            Darwin.exit(1)
        }

        let socketServer = SocketServer(authHandler: webHandler, policyEngine: policyEngine)
        do {
            try socketServer.start()
            print("  Socket: \(socketServer.path)")
            print("  Web:    http://localhost:\(webPort)")
            print("")
            print("  Ready. Waiting for auth requests...")
            print("  When sudo runs, a URL will appear — open it on any phone to approve.")
            print("")
        } catch {
            print("Error: Failed to start socket server: \(error)")
            Darwin.exit(1)
        }

        setupShutdownHandler {
            print("\nShutting down web companion...")
            socketServer.stop()
            webCompanion.stop()
        }

        RunLoop.current.run()
    }

    private func runNormalMode() throws {
        print("touchbridged v0.1.0-dev starting...")

        let policyEngine = PolicyEngine()
        let coordinator = DaemonCoordinator(rssiThreshold: rssiThreshold)

        // Proximity auto-lock
        var proximityMonitor: ProximityMonitor?
        if autoLock {
            let monitor = ProximityMonitor(rssiThreshold: rssiThreshold - 5)
            monitor.enable()
            monitor.onShouldLock = {
                print("Proximity auto-lock: locking screen")
            }
            proximityMonitor = monitor

            coordinator.onChallengeResult = { challengeID, result, deviceID in
                print("Challenge \(challengeID): \(result) (device: \(deviceID ?? "unknown"))")
            }
        } else {
            coordinator.onChallengeResult = { challengeID, result, deviceID in
                print("Challenge \(challengeID): \(result) (device: \(deviceID ?? "unknown"))")
            }
        }

        coordinator.onPairingComplete = { device in
            print("Paired with \(device.displayName) (\(device.deviceID))")
        }

        // Start Unix domain socket server for PAM module communication
        let socketServer = SocketServer(authHandler: coordinator, policyEngine: policyEngine)
        do {
            try socketServer.start()
            print("Socket server listening on \(socketServer.path)")
        } catch {
            print("Warning: Failed to start socket server: \(error)")
            print("PAM module authentication will not be available.")
        }

        coordinator.start()

        // Wait for BLE to be ready, then start advertising
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            coordinator.startAdvertising()
            print("Advertising TouchBridge service over BLE...")
            print("Waiting for companion device connections.")
            if self.autoLock {
                print("Proximity auto-lock: ENABLED")
            }
        }

        setupShutdownHandler {
            print("\nShutting down...")
            socketServer.stop()
            coordinator.stop()
            proximityMonitor?.disable()
        }

        print("Press Ctrl+C to stop.")
        RunLoop.current.run()
    }

    private func setupShutdownHandler(_ cleanup: @escaping () -> Void) {
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            cleanup()
            Darwin.exit(0)
        }
        sigintSource.resume()
    }
}
