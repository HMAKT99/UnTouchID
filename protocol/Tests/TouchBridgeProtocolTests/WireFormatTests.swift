import Testing
import Foundation
@testable import TouchBridgeProtocol

@Test func roundTripPairRequest() throws {
    let msg = PairRequestMessage(deviceName: "Test iPhone", publicKey: Data(repeating: 0x01, count: 65))
    let encoded = try WireFormat.encode(.pairRequest, msg)
    let (type, payload) = try WireFormat.decode(data: encoded)

    #expect(type == .pairRequest)
    let decoded = try WireFormat.decodePayload(PairRequestMessage.self, from: payload)
    #expect(decoded.deviceName == "Test iPhone")
    #expect(decoded.publicKey == Data(repeating: 0x01, count: 65))
}

@Test func roundTripChallengeIssued() throws {
    let msg = ChallengeIssuedMessage(
        challengeID: "test-uuid",
        encryptedNonce: Data(repeating: 0xAB, count: 60),
        reason: "sudo",
        expiryUnix: 1234567890
    )
    let encoded = try WireFormat.encode(.challengeIssued, msg)
    let (type, payload) = try WireFormat.decode(data: encoded)

    #expect(type == .challengeIssued)
    let decoded = try WireFormat.decodePayload(ChallengeIssuedMessage.self, from: payload)
    #expect(decoded.challengeID == "test-uuid")
    #expect(decoded.reason == "sudo")
    #expect(decoded.expiryUnix == 1234567890)
}

@Test func roundTripChallengeResponse() throws {
    let msg = ChallengeResponseMessage(
        challengeID: "resp-uuid",
        signature: Data(repeating: 0xCC, count: 72),
        deviceID: "device-123"
    )
    let encoded = try WireFormat.encode(.challengeResponse, msg)
    let (type, payload) = try WireFormat.decode(data: encoded)

    #expect(type == .challengeResponse)
    let decoded = try WireFormat.decodePayload(ChallengeResponseMessage.self, from: payload)
    #expect(decoded.deviceID == "device-123")
    #expect(decoded.signature.count == 72)
}

@Test func oversizeMessageThrows() throws {
    // Create a message that exceeds 256 bytes
    let largeKey = Data(repeating: 0xFF, count: 300)
    let msg = PairRequestMessage(deviceName: "Big", publicKey: largeKey)

    #expect(throws: WireFormatError.self) {
        try WireFormat.encode(.pairRequest, msg)
    }
}

@Test func tooSmallDataThrows() throws {
    let tiny = Data([0x01]) // only 1 byte, need at least 2

    #expect(throws: WireFormatError.self) {
        try WireFormat.decode(data: tiny)
    }
}

@Test func unknownTypeThrows() throws {
    var data = Data([TouchBridgeConstants.protocolVersion, 0xFF])
    data.append(Data("{}".utf8))

    #expect(throws: WireFormatError.self) {
        try WireFormat.decode(data: data)
    }
}

@Test func versionByteIsPresent() throws {
    let msg = ErrorMessage(code: 42, description: "test")
    let encoded = try WireFormat.encode(.error, msg)

    #expect(encoded[0] == TouchBridgeConstants.protocolVersion)
    #expect(encoded[1] == MessageType.error.rawValue)
}

@Test func emptyPayloadDecodes() throws {
    let msg = ErrorMessage(code: 0, description: "")
    let encoded = try WireFormat.encode(.error, msg)
    let (type, payload) = try WireFormat.decode(data: encoded)

    #expect(type == .error)
    let decoded = try WireFormat.decodePayload(ErrorMessage.self, from: payload)
    #expect(decoded.code == 0)
    #expect(decoded.description == "")
}
