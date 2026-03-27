import Foundation
import Security
import OSLog

/// Simulated companion device that handles auth requests locally
/// without BLE or a real iPhone.
///
/// Uses software P-256 keys to simulate the Secure Enclave signing flow.
/// Runs the full ChallengeManager pipeline (nonce → sign → verify) in-process.
///
/// Modes:
/// - `.autoApprove`: Automatically approves every auth request
/// - `.interactive`: Prompts in the terminal for approve/deny
/// - `.autoDeny`: Automatically denies every auth request (for testing fallback)
public final class SimulatorAuthHandler: PAMAuthHandler, @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "Simulator")

    public enum Mode: String, Sendable {
        case autoApprove = "auto-approve"
        case interactive = "interactive"
        case autoDeny = "auto-deny"
    }

    private let mode: Mode
    private let challengeManager: ChallengeManager
    private let auditLog: AuditLog
    private let simulatedDeviceID: String

    // Software key pair (simulating Secure Enclave)
    private let privateKey: SecKey
    private let publicKey: SecKey

    public init(
        mode: Mode = .autoApprove,
        challengeManager: ChallengeManager = ChallengeManager(),
        auditLog: AuditLog = AuditLog()
    ) {
        self.mode = mode
        self.challengeManager = challengeManager
        self.auditLog = auditLog
        self.simulatedDeviceID = "simulator-\(UUID().uuidString.prefix(8))"

        // Generate software P-256 key pair
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        self.privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error)!
        self.publicKey = SecKeyCopyPublicKey(self.privateKey)!

        logger.info("Simulator initialized in \(mode.rawValue) mode (device: \(self.simulatedDeviceID))")
    }

    public func authenticateFromPAM(
        user: String,
        service: String,
        pid: Int,
        timeout: TimeInterval
    ) async -> (success: Bool, reason: String?) {
        let startTime = Date()

        // Check mode
        let approved: Bool
        switch mode {
        case .autoApprove:
            print("  SIMULATOR: Auto-approving auth for \(user) (\(service))")
            approved = true

        case .autoDeny:
            print("  SIMULATOR: Auto-denying auth for \(user) (\(service))")
            approved = false

        case .interactive:
            print("")
            print("  ┌─────────────────────────────────────────┐")
            print("  │  TouchBridge Authentication Request      │")
            print("  ├─────────────────────────────────────────┤")
            print("  │  User:    \(user.padding(toLength: 30, withPad: " ", startingAt: 0))│")
            print("  │  Service: \(service.padding(toLength: 30, withPad: " ", startingAt: 0))│")
            print("  │  PID:     \(String(pid).padding(toLength: 30, withPad: " ", startingAt: 0))│")
            print("  └─────────────────────────────────────────┘")
            print("  Approve? [Y/n] ", terminator: "")

            if let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                approved = input.isEmpty || input == "y" || input == "yes"
            } else {
                approved = false
            }
        }

        guard approved else {
            await auditLog.log(AuditEntry(
                sessionID: UUID().uuidString,
                surface: "pam_\(service)",
                requestingProcess: service,
                companionDevice: "Simulator",
                deviceID: simulatedDeviceID,
                result: "FAILED_BIOMETRIC"
            ))
            return (false, "user_denied")
        }

        // Run the full crypto pipeline: issue challenge → sign → verify
        do {
            let challenge = try await challengeManager.issue(for: simulatedDeviceID)

            // Sign the nonce with our software key (simulating Secure Enclave)
            var signError: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                privateKey,
                .ecdsaSignatureMessageX962SHA256,
                challenge.nonce as CFData,
                &signError
            ) as Data? else {
                return (false, "signing_failed")
            }

            // Verify the signature (using the public key)
            let result = await challengeManager.verify(
                challengeID: challenge.id,
                signature: signature,
                publicKey: publicKey
            )

            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)

            let resultString = result == .verified ? "VERIFIED" : "FAILED"
            await auditLog.log(AuditEntry(
                sessionID: challenge.id.uuidString,
                surface: "pam_\(service)",
                requestingProcess: service,
                companionDevice: "Simulator",
                deviceID: simulatedDeviceID,
                result: resultString,
                authType: "simulated",
                latencyMs: latencyMs
            ))

            if result == .verified {
                print("  SIMULATOR: VERIFIED (latency: \(latencyMs)ms)")
                return (true, nil)
            } else {
                return (false, "verification_failed")
            }
        } catch {
            logger.error("Simulator auth failed: \(error.localizedDescription)")
            return (false, "simulator_error")
        }
    }
}
