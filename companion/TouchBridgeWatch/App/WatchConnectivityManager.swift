import Foundation
import WatchConnectivity
import UserNotifications

/// Manages communication between the Watch and the iPhone companion app.
///
/// Flow:
/// 1. iPhone receives BLE challenge from Mac daemon
/// 2. iPhone sends challenge to Watch via WatchConnectivity
/// 3. Watch shows approve/deny prompt
/// 4. User taps approve (or double-clicks side button)
/// 5. Watch sends approval back to iPhone
/// 6. iPhone signs the nonce and sends response to Mac
///
/// The Watch does NOT do any cryptography — it's purely an approval UI.
/// The iPhone handles all signing with its Secure Enclave.
class WatchConnectivityManager: NSObject, ObservableObject, WCSessionDelegate {

    @Published var isReachable: Bool = false
    @Published var isPaired: Bool = false
    @Published var pendingChallenge: WatchChallenge?
    @Published var lastResult: String?
    @Published var challengeCount: Int = 0

    struct WatchChallenge: Identifiable {
        let id = UUID()
        let challengeID: String
        let reason: String
        let macName: String
        let user: String
        let timestamp: Date
    }

    private var session: WCSession?

    override init() {
        super.init()

        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }

    // MARK: - Actions

    func approve() {
        guard let challenge = pendingChallenge else { return }

        let response: [String: Any] = [
            "type": "auth_response",
            "challengeID": challenge.challengeID,
            "approved": true,
        ]

        session?.sendMessage(response, replyHandler: nil) { error in
            print("Failed to send approval: \(error.localizedDescription)")
        }

        challengeCount += 1
        lastResult = "Approved"
        pendingChallenge = nil

        // Haptic feedback
        WKInterfaceDevice.current().play(.success)
    }

    func deny() {
        guard let challenge = pendingChallenge else { return }

        let response: [String: Any] = [
            "type": "auth_response",
            "challengeID": challenge.challengeID,
            "approved": false,
        ]

        session?.sendMessage(response, replyHandler: nil) { error in
            print("Failed to send denial: \(error.localizedDescription)")
        }

        lastResult = "Denied"
        pendingChallenge = nil

        WKInterfaceDevice.current().play(.failure)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            self.isPaired = activationState == .activated
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
    }

    /// Receives auth challenge from iPhone companion app.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let type = message["type"] as? String, type == "auth_challenge" else { return }

        let challenge = WatchChallenge(
            challengeID: message["challengeID"] as? String ?? "",
            reason: message["reason"] as? String ?? "Authentication",
            macName: message["macName"] as? String ?? "Mac",
            user: message["user"] as? String ?? "",
            timestamp: Date()
        )

        DispatchQueue.main.async {
            self.pendingChallenge = challenge
            // Haptic to alert user
            WKInterfaceDevice.current().play(.notification)
        }
    }

    /// Receives auth challenge via user info transfer (background).
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        // Same handling as message — for when Watch app is in background
        self.session(session, didReceiveMessage: userInfo)
    }
}
