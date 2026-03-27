import Foundation
import OSLog

/// UI helper for the authorization plugin.
///
/// When the authorization plugin is invoked, it can display a minimal
/// "Check your iPhone" message via SecurityAgent or system notification.
///
/// In Phase 3, this is a logging placeholder. The actual SecurityAgent
/// UI integration requires entitlements and signing with Developer ID.
struct AuthUI {
    private static let logger = Logger(subsystem: "dev.touchbridge", category: "AuthUI")

    /// Show a "Check your iPhone" prompt.
    /// In production, this would display via SecurityAgent's UI mechanism.
    static func showCheckYourPhone(reason: String) {
        logger.info("Auth request: \(reason) — check your iPhone")
        // SecurityAgent UI integration would go here.
        // Requires Developer ID signing and notarization.
    }

    /// Dismiss the prompt.
    static func dismiss() {
        logger.info("Auth prompt dismissed")
    }
}
