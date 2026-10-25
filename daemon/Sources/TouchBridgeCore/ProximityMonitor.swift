import CoreGraphics
import Foundation
import OSLog

/// Locks only after the last verified companion leaves. Initial absence does
/// not arm auto-lock; unauthenticated BLE connections and RSSI cannot cancel it.
public final class ProximityMonitor: @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "ProximityMonitor")
    private let rssiThreshold: Int
    private let disconnectDelay: TimeInterval
    private let stateLock = NSLock()
    private var isEnabled = false
    private var verifiedCount = 0
    private var hasObservedVerifiedCompanion = false
    private var generation: UInt64 = 0
    private var disconnectTimer: DispatchWorkItem?
    private let queue = DispatchQueue(label: "dev.touchbridge.proximity")
    private let lockAction: () throws -> Void

    /// Legacy notification that a lock attempt is starting, not proof of success.
    public var onShouldLock: (() -> Void)?
    /// Success requires the system lock state to be confirmed after the command.
    public var onLockResult: ((Result<Void, Error>) -> Void)?

    public convenience init(rssiThreshold: Int = -80, disconnectDelay: TimeInterval = 30) {
        self.init(rssiThreshold: rssiThreshold, disconnectDelay: disconnectDelay) {
            try SessionLockController.lock()
        }
    }

    init(rssiThreshold: Int, disconnectDelay: TimeInterval, lockAction: @escaping () throws -> Void) {
        self.rssiThreshold = rssiThreshold
        self.disconnectDelay = disconnectDelay.isFinite ? min(300, max(0, disconnectDelay)) : 30
        self.lockAction = lockAction
    }

    public func enable() {
        stateLock.withLock {
            isEnabled = true
            if verifiedCount > 0 { hasObservedVerifiedCompanion = true }
        }
        logger.info("Verified companion auto-lock enabled (delay: \(self.disconnectDelay)s)")
    }

    public func disable() {
        stateLock.withLock {
            isEnabled = false
            cancelPendingLock()
        }
        logger.info("Proximity auto-lock disabled")
    }

    /// Supply only the number of peers with a live, authenticated session.
    public func verifiedCompanionCountChanged(_ count: Int) {
        stateLock.withLock {
            guard count >= 0 else { return }
            let previousCount = verifiedCount
            verifiedCount = count
            guard isEnabled else { return }
            if count > 0 {
                hasObservedVerifiedCompanion = true
                cancelPendingLock()
            } else if previousCount > 0 && hasObservedVerifiedCompanion {
                cancelPendingLock()
                let expectedGeneration = generation
                let workItem = DispatchWorkItem { [weak self] in
                    self?.lockIfStillAbsent(generation: expectedGeneration)
                }
                disconnectTimer = workItem
                queue.asyncAfter(deadline: .now() + disconnectDelay, execute: workItem)
            }
        }
    }

    /// Compatibility for callers that already verify the single companion.
    /// Raw BLE connect/disconnect events must not use this API.
    @available(*, deprecated, message: "Use verifiedCompanionCountChanged with authenticated session counts")
    public func connectionStateChanged(connected: Bool) {
        verifiedCompanionCountChanged(connected ? 1 : 0)
    }

    public func rssiUpdated(_ rssi: Int) {
        if enabled && rssi < rssiThreshold {
            logger.debug("RSSI below threshold; only verified session lifecycle controls auto-lock")
        }
    }

    private func cancelPendingLock() {
        generation &+= 1
        disconnectTimer?.cancel()
        disconnectTimer = nil
    }

    private func lockIfStillAbsent(generation expectedGeneration: UInt64) {
        let shouldAttempt = stateLock.withLock {
            guard isEnabled, verifiedCount == 0, hasObservedVerifiedCompanion,
                  generation == expectedGeneration else { return false }
            disconnectTimer = nil
            return true
        }
        guard shouldAttempt else { return }
        onShouldLock?()
        do {
            try lockAction()
            logger.info("Session lock state confirmed")
            onLockResult?(.success(()))
        } catch {
            logger.error("Session lock failed: \(error.localizedDescription)")
            onLockResult?(.failure(error))
        }
    }

    public var enabled: Bool { stateLock.withLock { isEnabled } }
}

public enum SessionLockError: Error, LocalizedError, Equatable {
    case mechanismUnavailable
    case stateUnavailable
    case commandFailed(Int32)
    case commandTimedOut
    case notConfirmed

    public var errorDescription: String? {
        switch self {
        case .mechanismUnavailable: return "No supported session lock command is available."
        case .stateUnavailable: return "macOS session lock state is unavailable; locking cannot be confirmed."
        case .commandFailed(let status): return "Session lock command failed (status \(status)); check Automation and Accessibility permissions."
        case .commandTimedOut: return "Session lock command timed out."
        case .notConfirmed: return "macOS did not confirm the session was locked."
        }
    }
}

/// Injectable command and readback boundary; tests never execute a real lock.
enum SessionLockController {
    static let cgSessionPath = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"

    static func lock(
        run: (String, [String]) throws -> Void = runCommand,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        probe: () -> Bool? = systemLockState,
        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.1) },
        verificationAttempts: Int = 20
    ) throws {
        // On unlocked macOS sessions the lock property may be absent. Only a
        // positive readback proves locking; absence must not block the attempt.
        if probe() == true { return }
        if exists(cgSessionPath) {
            try run(cgSessionPath, ["-suspend"])
        } else if exists("/usr/bin/osascript") {
            // Apple documents Control-Command-Q as Lock Screen. Permissions may
            // deny this request; command success alone is never locking evidence.
            try run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to key code 12 using {control down, command down}"])
        } else {
            throw SessionLockError.mechanismUnavailable
        }
        var finalState: Bool?
        for _ in 0..<max(1, min(50, verificationAttempts)) {
            finalState = probe()
            if finalState == true { return }
            pause()
        }
        if finalState == nil { throw SessionLockError.stateUnavailable }
        throw SessionLockError.notConfirmed
    }

    private static func systemLockState() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        // This property is not available on every macOS release. Missing state
        // fails closed instead of assuming a successful command locked the Mac.
        return session["CGSSessionScreenIsLocked"] as? Bool
    }

    private static func runCommand(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            throw SessionLockError.commandTimedOut
        }
        guard process.terminationStatus == 0 else {
            throw SessionLockError.commandFailed(process.terminationStatus)
        }
    }
}
