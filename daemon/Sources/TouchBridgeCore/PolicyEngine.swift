import Foundation
import OSLog

/// Authentication mode for a given surface.
public enum AuthMode: String, Codable, Sendable {
    /// Always require biometric confirmation on companion device.
    case biometricRequired = "biometric_required"
    /// Allow proximity session — if device was authenticated recently within TTL, skip biometric.
    case proximitySession = "proximity_session"
}

/// Per-surface policy configuration.
public struct SurfacePolicy: Codable, Sendable {
    public let mode: AuthMode
    /// Session TTL in seconds (only used when mode == .proximitySession).
    public let sessionTTLSeconds: TimeInterval

    public init(mode: AuthMode, sessionTTLSeconds: TimeInterval = 0) {
        self.mode = mode
        self.sessionTTLSeconds = sessionTTLSeconds
    }
}

/// Manages per-action authentication policy.
///
/// Default policy:
/// - sudo → always require biometric
/// - screensaver → proximity session (30 min)
/// - app_store → always require biometric
/// - system_settings → always require biometric
/// - browser_autofill → proximity session (10 min)
///
/// Reads overrides from `~/Library/Application Support/TouchBridge/policy.plist`.
public final class PolicyEngine: Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "PolicyEngine")
    private let plistPath: String

    /// Default policies per surface.
    private static let defaults: [String: SurfacePolicy] = [
        "sudo": SurfacePolicy(mode: .biometricRequired),
        "screensaver": SurfacePolicy(mode: .proximitySession, sessionTTLSeconds: 1800),
        "app_store": SurfacePolicy(mode: .biometricRequired),
        "system_settings": SurfacePolicy(mode: .biometricRequired),
        "browser_autofill": SurfacePolicy(mode: .proximitySession, sessionTTLSeconds: 600),
    ]

    /// Active proximity sessions: surface → expiry time.
    private let sessions = ProximitySessionStore()

    public init(plistPath: String? = nil) {
        if let path = plistPath {
            self.plistPath = path
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.plistPath = "\(home)/Library/Application Support/TouchBridge/policy.plist"
        }
    }

    /// Get the policy for a given surface (e.g., "sudo", "screensaver").
    public func policy(for surface: String) -> SurfacePolicy {
        // Check user overrides from plist
        if let dict = NSDictionary(contentsOfFile: plistPath),
           let surfaces = dict["Surfaces"] as? [String: [String: Any]],
           let surfaceDict = surfaces[surface],
           let modeStr = surfaceDict["mode"] as? String,
           let mode = AuthMode(rawValue: modeStr) {
            let ttl = surfaceDict["sessionTTLSeconds"] as? TimeInterval ?? 0
            return SurfacePolicy(mode: mode, sessionTTLSeconds: ttl)
        }

        // Fall back to defaults
        return Self.defaults[surface] ?? SurfacePolicy(mode: .biometricRequired)
    }

    /// Determine whether biometric auth is needed for this surface right now.
    ///
    /// Returns `true` if biometric is required, `false` if a valid proximity session exists.
    public func requiresBiometric(for surface: String, deviceID: String) -> Bool {
        let pol = policy(for: surface)

        switch pol.mode {
        case .biometricRequired:
            return true
        case .proximitySession:
            // Check if there's a valid session
            if sessions.isValid(surface: surface, deviceID: deviceID) {
                return false
            }
            return true
        }
    }

    /// Record a successful biometric auth, starting a proximity session if applicable.
    public func recordAuthentication(surface: String, deviceID: String) {
        let pol = policy(for: surface)
        if pol.mode == .proximitySession && pol.sessionTTLSeconds > 0 {
            sessions.create(surface: surface, deviceID: deviceID, ttl: pol.sessionTTLSeconds)
        }
    }

    /// Invalidate all proximity sessions (e.g., on device disconnect).
    public func invalidateAllSessions() {
        sessions.clear()
    }

    /// Authentication timeout in seconds. Defaults to 15s if not configured.
    public func authTimeout() -> TimeInterval {
        guard let dict = NSDictionary(contentsOfFile: plistPath),
              let timeout = dict["AuthTimeoutSeconds"] as? Double,
              timeout > 0 else {
            return 15.0
        }
        return timeout
    }

    /// Default RSSI threshold for proximity gate. Defaults to -75 dBm.
    public func rssiThreshold() -> Int {
        guard let dict = NSDictionary(contentsOfFile: plistPath),
              let threshold = dict["RSSIThreshold"] as? Int else {
            return -75
        }
        return threshold
    }

    /// List all configured surface policies (defaults + overrides).
    public func allPolicies() -> [String: SurfacePolicy] {
        var result = Self.defaults

        if let dict = NSDictionary(contentsOfFile: plistPath),
           let surfaces = dict["Surfaces"] as? [String: [String: Any]] {
            for (surface, surfaceDict) in surfaces {
                if let modeStr = surfaceDict["mode"] as? String,
                   let mode = AuthMode(rawValue: modeStr) {
                    let ttl = surfaceDict["sessionTTLSeconds"] as? TimeInterval ?? 0
                    result[surface] = SurfacePolicy(mode: mode, sessionTTLSeconds: ttl)
                }
            }
        }

        return result
    }
}

/// Thread-safe proximity session storage.
final class ProximitySessionStore: @unchecked Sendable {
    private var sessions: [String: Date] = [:] // key: "surface:deviceID" → expiry
    private let lock = NSLock()

    func create(surface: String, deviceID: String, ttl: TimeInterval) {
        let key = "\(surface):\(deviceID)"
        lock.lock()
        sessions[key] = Date().addingTimeInterval(ttl)
        lock.unlock()
    }

    func isValid(surface: String, deviceID: String) -> Bool {
        let key = "\(surface):\(deviceID)"
        lock.lock()
        defer { lock.unlock() }
        guard let expiry = sessions[key] else { return false }
        if Date() < expiry {
            return true
        }
        sessions.removeValue(forKey: key)
        return false
    }

    func clear() {
        lock.lock()
        sessions.removeAll()
        lock.unlock()
    }
}
