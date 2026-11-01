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
        do {
            (message, payload) = try validatedChallenge(encryptedData)
        } catch {
            return .failed(.parseFailed)
        }

        // Consume before prompting, including denied/cancelled attempts.
        guard registerNonceIfFresh(nonce: payload.nonce, expiry: payload.expiry) else {
            return .failed(.parseFailed)
        }

        cancel()
        let token = generation
        let reason = "TouchBridge: \(payload.user) — \(payload.service) (PID \(payload.pid))"

        do {
            let approved = try await performAuthentication(reason: reason)
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
            sendErrorResponse(code: .keyInvalidated, description: "key_invalidated", challengeID: message.challengeID, session: session)
            return .failed(.keyInvalidated)
        } catch {
            return .failed(.biometricDenied)
        }
    }

    private func registerNonceIfFresh(nonce: Data, expiry: UInt64) -> Bool {
        let now = UInt64(Date().timeIntervalSince1970)
        seen = seen.filter { $0.value > now }
        guard seen[nonce] == nil, seen.count < 512 else { return false }
        seen[nonce] = expiry
        return true
    }

    private func performAuthentication(reason: String) async throws -> Bool {
        if let authenticate {
            return try await authenticate(reason)
        }
        return try await localAuth.authenticateUser(reason: reason)
    }

    private func sendErrorResponse(code: ErrorCode, description: String, challengeID: String, session: SessionCrypto) {
        let errorMsg = ErrorMessage(code: code.rawValue, description: description, challengeID: challengeID)
        if let bytes = try? WireFormat.seal(.error, errorMsg, crypto: session) {
            _ = sendResponse?(bytes)
        }
    }
}
public enum ChallengeHandlerResult: Sendable { case success(challengeID: String), failed(ChallengeHandlerError) }
public enum ChallengeHandlerError: String, Sendable, CustomStringConvertible {
    case noSession, decryptionFailed, parseFailed, expired, biometricDenied, signingFailed, keyInvalidated, encodingFailed, sendFailed
    public var description: String { rawValue }
}
