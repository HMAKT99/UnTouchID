import Foundation
import WatchConnectivity
import os.log

/// Relays authentication challenges from the Mac (via BLE) to the Apple Watch.
///
/// When a challenge arrives on the iPhone:
/// 1. If Watch is reachable → send challenge to Watch for approval
/// 2. Watch shows approve/deny UI
/// 3. Watch sends response back to iPhone
/// 4. iPhone signs the nonce with Secure Enclave and sends to Mac
///
/// If Watch is not reachable, falls back to iPhone Face ID as usual.
public final class WatchRelay: NSObject, ObservableObject, WCSessionDelegate {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "WatchRelay")

    @Published public var isWatchReachable: Bool = false
    @Published public var isWatchPaired: Bool = false

    /// Callback when Watch approves/denies a challenge.
    public var onWatchResponse: ((String, Bool) -> Void)?

    private var session: WCSession?

    public override init() {
        super.init()

        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
            logger.info("WatchConnectivity session activated")
        } else {
            logger.info("WatchConnectivity not supported on this device")
        }
    }

    /// Send an auth challenge to the Watch for approval.
    ///
    /// Returns true if the Watch is reachable and the message was sent.
    public func sendChallengeToWatch(
        challengeID: String,
        reason: String,
        macName: String,
        user: String
    ) -> Bool {
        guard let session, session.isReachable else {
            logger.info("Watch not reachable — falling back to iPhone")
            return false
        }

        let message: [String: Any] = [
            "type": "auth_challenge",
            "challengeID": challengeID,
            "reason": reason,
            "macName": macName,
            "user": user,
        ]

        session.sendMessage(message, replyHandler: nil) { [weak self] error in
            self?.logger.error("Failed to send challenge to Watch: \(error.localizedDescription)")
        }

        logger.info("Challenge sent to Watch: \(challengeID)")
        return true
    }

    // MARK: - WCSessionDelegate

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.isWatchPaired = session.isPaired
            self.isWatchReachable = session.isReachable
        }
        logger.info("Watch session activated: paired=\(session.isPaired), reachable=\(session.isReachable)")
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {
        logger.info("Watch session became inactive")
    }

    public func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for new Watch pairing
        session.activate()
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
        }
        logger.info("Watch reachability changed: \(session.isReachable)")
    }

    /// Receives approval/denial from the Watch.
    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let type = message["type"] as? String, type == "auth_response" else { return }

        let challengeID = message["challengeID"] as? String ?? ""
        let approved = message["approved"] as? Bool ?? false

        logger.info("Watch response: challengeID=\(challengeID), approved=\(approved)")

        DispatchQueue.main.async {
            self.onWatchResponse?(challengeID, approved)
        }
    }
}
