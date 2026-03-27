import Foundation

/// Wire message type identifier — first byte of every message.
public enum MessageType: UInt8, Codable, Sendable {
    case pairRequest = 1
    case pairResponse = 2
    case challengeIssued = 3
    case challengeResponse = 4
    case error = 5
}

// MARK: - Message Payloads

public struct PairRequestMessage: Codable, Sendable {
    public let deviceName: String
    public let publicKey: Data

    public init(deviceName: String, publicKey: Data) {
        self.deviceName = deviceName
        self.publicKey = publicKey
    }
}

public struct PairResponseMessage: Codable, Sendable {
    public let deviceID: String
    public let publicKey: Data
    public let accepted: Bool

    public init(deviceID: String, publicKey: Data, accepted: Bool) {
        self.deviceID = deviceID
        self.publicKey = publicKey
        self.accepted = accepted
    }
}

public struct ChallengeIssuedMessage: Codable, Sendable {
    public let challengeID: String
    public let encryptedNonce: Data
    public let reason: String
    public let expiryUnix: UInt64

    public init(challengeID: String, encryptedNonce: Data, reason: String, expiryUnix: UInt64) {
        self.challengeID = challengeID
        self.encryptedNonce = encryptedNonce
        self.reason = reason
        self.expiryUnix = expiryUnix
    }
}

public struct ChallengeResponseMessage: Codable, Sendable {
    public let challengeID: String
    public let signature: Data
    public let deviceID: String

    public init(challengeID: String, signature: Data, deviceID: String) {
        self.challengeID = challengeID
        self.signature = signature
        self.deviceID = deviceID
    }
}

public struct ErrorMessage: Codable, Sendable {
    public let code: UInt16
    public let description: String

    public init(code: UInt16, description: String) {
        self.code = code
        self.description = description
    }
}
