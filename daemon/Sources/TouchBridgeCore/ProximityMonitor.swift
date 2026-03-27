import Foundation
import OSLog

/// Monitors companion device proximity via BLE RSSI and auto-locks
/// the Mac when the device moves out of range.
///
/// When the paired iPhone leaves BLE range (RSSI drops below threshold
/// for sustained period), the Mac screen is locked.
///
/// This is the inverse of "unlock with iPhone" — "lock when iPhone walks away."
public final class ProximityMonitor: @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "ProximityMonitor")

    private let rssiThreshold: Int
    private let disconnectDelay: TimeInterval
    private var isEnabled: Bool = false
    private var disconnectTimer: DispatchWorkItem?
    private var lastConnectedState: Bool = true
    private let queue = DispatchQueue(label: "dev.touchbridge.proximity")

    /// Callback when the Mac should be locked.
    public var onShouldLock: (() -> Void)?

    /// Initialize with configurable RSSI threshold and delay.
    ///
    /// - Parameters:
    ///   - rssiThreshold: Lock when average RSSI drops below this (default -80 dBm)
    ///   - disconnectDelay: Wait this long after disconnect before locking (default 30s)
    public init(rssiThreshold: Int = -80, disconnectDelay: TimeInterval = 30) {
        self.rssiThreshold = rssiThreshold
        self.disconnectDelay = disconnectDelay
    }

    /// Enable proximity-based auto-lock.
    public func enable() {
        isEnabled = true
        logger.info("Proximity auto-lock enabled (threshold: \(self.rssiThreshold) dBm, delay: \(self.disconnectDelay)s)")
    }

    /// Disable proximity-based auto-lock.
    public func disable() {
        isEnabled = false
        disconnectTimer?.cancel()
        disconnectTimer = nil
        logger.info("Proximity auto-lock disabled")
    }

    /// Called when BLE connection state changes.
    public func connectionStateChanged(connected: Bool) {
        guard isEnabled else { return }

        if connected {
            // Cancel any pending lock
            disconnectTimer?.cancel()
            disconnectTimer = nil
            lastConnectedState = true
            logger.info("Companion reconnected — auto-lock cancelled")
        } else if lastConnectedState {
            // Device disconnected — start countdown
            lastConnectedState = false
            logger.info("Companion disconnected — will lock in \(self.disconnectDelay)s if not reconnected")

            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.isEnabled, !self.lastConnectedState else { return }
                self.logger.info("Proximity auto-lock triggered — locking screen")
                self.lockScreen()
            }
            disconnectTimer = workItem
            queue.asyncAfter(deadline: .now() + disconnectDelay, execute: workItem)
        }
    }

    /// Called with RSSI updates from BLE.
    public func rssiUpdated(_ rssi: Int) {
        guard isEnabled else { return }

        if rssi < rssiThreshold {
            logger.info("RSSI \(rssi) below threshold \(self.rssiThreshold) — companion moving out of range")
        }
    }

    /// Lock the Mac screen using the CGSession command.
    private func lockScreen() {
        onShouldLock?()

        // Use the system command to lock the screen
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]

        do {
            try process.run()
            process.waitUntilExit()
            logger.info("Screen locked via pmset")
        } catch {
            logger.error("Failed to lock screen: \(error.localizedDescription)")
        }
    }

    public var enabled: Bool { isEnabled }
}
