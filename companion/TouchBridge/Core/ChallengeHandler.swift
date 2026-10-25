import Foundation
import CryptoKit

/// A cancellable authorization flow. Only validated canonical bytes reach UI or signing.
@MainActor
public final class ChallengeHandler {
    private let signingProvider: SigningProvider
    private let localAuth: LocalAuthManager
    private let signingKeyTag: String
    private var generation: UInt64 = 0
    private var seen: [Data: UInt64] = [:]
    private let authenticate: (@MainActor (String) async throws -> Bool)?
    public var sessionCrypto: SessionCrypto? { didSet { cancel() } }
    public var macIdentityHash: Data?
    public var sendResponse: ((Data) -> Bool)?
    public init(signingProvider: SigningProvider, localAuth: LocalAuthManager, signingKeyTag: String = "dev.touchbridge.signing", authenticate: (@MainActor (String) async throws -> Bool)? = nil) {
        self.signingProvider = signingProvider; self.localAuth = localAuth; self.signingKeyTag = signingKeyTag; self.authenticate = authenticate
    }
    public func cancel() { generation &+= 1; localAuth.cancel() }
    public func validatedChallenge(_ data: Data) throws -> (AuthorizationChallengeMessage, AuthorizationPayload) {
        guard let session = sessionCrypto, let hash = macIdentityHash else { throw ProtocolSecurityError.identityMismatch }
        let decoded = try WireFormat.open(data, crypto: session)
        guard decoded.type == .challengeIssued else { throw ProtocolSecurityError.malformed }
        let message = try WireFormat.decodePayload(AuthorizationChallengeMessage.self, from: decoded.payload)
        guard UUID(uuidString: message.challengeID) != nil else { throw ProtocolSecurityError.malformed }
        let payload = try AuthorizationPayload.parse(message.authorization)
        try payload.validate(macIdentityHash: hash)
        return (message, payload)
    }
    public func handleChallenge(encryptedData: Data, deviceID: String) async -> ChallengeHandlerResult {
        guard let session = sessionCrypto else { return .failed(.noSession) }
        let message: AuthorizationChallengeMessage
        let payload: AuthorizationPayload
        do { (message, payload) = try validatedChallenge(encryptedData) } catch { return .failed(.parseFailed) }
        let now = UInt64(Date().timeIntervalSince1970)
        seen = seen.filter { $0.value > now }
        guard seen[payload.nonce] == nil, seen.count < 512 else { return .failed(.parseFailed) }
        // Consume before prompting, including denied/cancelled attempts.
        seen[payload.nonce] = payload.expiry
        cancel(); let token = generation
        let reason = "TouchBridge: \(payload.user) — \(payload.service) (PID \(payload.pid))"
        do {
            let approved: Bool
            if let authenticate { approved = try await authenticate(reason) } else { approved = try await localAuth.authenticateUser(reason: reason) }
            guard approved, token == generation, sessionCrypto != nil else { return .failed(.biometricDenied) }
            try payload.validate(macIdentityHash: macIdentityHash ?? Data())
            #if targetEnvironment(simulator)
            guard payload.purpose != .pam else { return .failed(.signingFailed) }
            #endif
            let signature = try signingProvider.sign(data: message.authorization, keyTag: signingKeyTag)
            guard token == generation, sessionCrypto != nil else { return .failed(.noSession) }
            try payload.validate(macIdentityHash: macIdentityHash ?? Data())
            let response = ChallengeResponseMessage(challengeID: message.challengeID, signature: signature, deviceID: deviceID)
            let bytes = try WireFormat.seal(.challengeResponse, response, crypto: session)
            guard sendResponse?(bytes) == true else { return .failed(.sendFailed) }
            return .success(challengeID: message.challengeID)
        } catch SecureEnclaveError.keyInvalidated {
            guard token == generation else { return .failed(.noSession) }
            if let bytes = try? WireFormat.seal(.error, ErrorMessage(code: ErrorCode.keyInvalidated.rawValue, description: "key_invalidated", challengeID: message.challengeID), crypto: session) { _ = sendResponse?(bytes) }
            return .failed(.keyInvalidated)
        } catch { return .failed(.biometricDenied) }
    }
}
public enum ChallengeHandlerResult: Sendable { case success(challengeID: String), failed(ChallengeHandlerError) }
public enum ChallengeHandlerError: String, Sendable, CustomStringConvertible {
    case noSession, decryptionFailed, parseFailed, expired, biometricDenied, signingFailed, keyInvalidated, encodingFailed, sendFailed
    public var description: String { rawValue }
}
