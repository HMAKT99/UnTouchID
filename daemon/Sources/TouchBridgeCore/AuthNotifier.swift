import Foundation
import UserNotifications
import OSLog

/// Sends macOS notifications for authentication events.
///
/// Useful for:
/// - Knowing someone tried to sudo while you were away
/// - Seeing failed auth attempts (potential security issue)
/// - Confirmation that auth succeeded
public final class AuthNotifier: @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "AuthNotifier")
    private var isEnabled: Bool = false

    public init() {}

    /// Enable notifications (requests permission on first call).
    public func enable() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            self?.isEnabled = granted
            if granted {
                self?.logger.info("Notifications enabled")
            } else {
                self?.logger.info("Notification permission denied: \(error?.localizedDescription ?? "unknown")")
            }
        }
    }

    /// Notify on successful authentication.
    public func notifySuccess(user: String, surface: String, device: String, latencyMs: Int) {
        guard isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "TouchBridge: ✓ Authenticated"
        content.body = "\(surface) for \(user) — approved via \(device) (\(latencyMs)ms)"
        content.sound = .default
        content.categoryIdentifier = "AUTH_SUCCESS"

        send(content, id: "success-\(UUID().uuidString)")
    }

    /// Notify on failed authentication.
    public func notifyFailure(user: String, surface: String, reason: String) {
        guard isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "TouchBridge: ✗ Auth Failed"
        content.body = "\(surface) for \(user) — \(reason)"
        content.sound = UNNotificationSound.defaultCritical
        content.categoryIdentifier = "AUTH_FAILURE"

        send(content, id: "failure-\(UUID().uuidString)")
    }

    /// Notify on timeout (phone unreachable).
    public func notifyTimeout(user: String, surface: String) {
        guard isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "TouchBridge: ⏱ Timed Out"
        content.body = "\(surface) for \(user) — phone not reachable, fell through to password"
        content.sound = .default
        content.categoryIdentifier = "AUTH_TIMEOUT"

        send(content, id: "timeout-\(UUID().uuidString)")
    }

    /// Notify on suspicious activity (repeated failures).
    public func notifySuspicious(failCount: Int, timeWindow: String) {
        guard isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "TouchBridge: ⚠️ Suspicious Activity"
        content.body = "\(failCount) failed auth attempts in \(timeWindow)"
        content.sound = UNNotificationSound.defaultCritical
        content.categoryIdentifier = "AUTH_SUSPICIOUS"

        send(content, id: "suspicious-\(UUID().uuidString)")
    }

    private func send(_ content: UNMutableNotificationContent, id: String) {
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to send notification: \(error.localizedDescription)")
            }
        }
    }
}
