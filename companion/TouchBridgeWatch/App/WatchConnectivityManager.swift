import Foundation
import WatchConnectivity
import UserNotifications

/// Watch authentication remains unavailable until the Watch can validate the
/// canonical authorization context. Never treat a loose message dictionary as
/// a trusted approval request.
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
        pendingChallenge = nil
        lastResult = "Open TouchBridge on iPhone to authenticate"
    }

    func deny() {
        pendingChallenge = nil
        lastResult = "No verified request"
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
        guard message["type"] as? String == "auth_challenge" else { return }
        DispatchQueue.main.async {
            self.pendingChallenge = nil
            self.lastResult = "Open TouchBridge on iPhone to authenticate"
        }
    }

    /// Receives auth challenge via user info transfer (background).
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        // Same handling as message — for when Watch app is in background
        self.session(session, didReceiveMessage: userInfo)
    }
}
