import XCTest
import CryptoKit
@testable import TouchBridgeProtocol

final class SecurityV2Tests: XCTestCase {
    func testNativePAMGoldenBytes() throws {
        let payload = AuthorizationPayload(purpose: .pam, nonce: Data(repeating: 0, count: 32), macIdentityHash: Data(repeating: 0, count: 32), uid: 501, pid: 123, issued: 100, expiry: 115, user: "alice", service: "sudo")
        let hex = try payload.encode().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "54422d4155544800020100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001f50000007b000000000000006400000000000000730005616c69636500047375646f")
    }
    func testCanonicalRoundtripAndRejectMalformed() throws {
        let now: UInt64 = 1_800_000_000
        let auth = AuthorizationPayload(purpose: .pam, nonce: Data(repeating: 1, count: 32), macIdentityHash: Data(repeating: 2, count: 32), uid: 501, pid: 42, issued: now, expiry: now + 10, user: "tester", service: "sudo")
        let bytes = try auth.encode()
        XCTAssertEqual(try AuthorizationPayload.parse(bytes), auth)
        XCTAssertNoThrow(try auth.validate(now: now, macIdentityHash: auth.macIdentityHash))
        XCTAssertThrowsError(try auth.validate(now: now, macIdentityHash: Data(repeating: 3, count: 32)))
        XCTAssertThrowsError(try AuthorizationPayload.parse(bytes + Data([0])))
        var bad = bytes; bad[8] = 1
        XCTAssertThrowsError(try AuthorizationPayload.parse(bad))
        XCTAssertThrowsError(try auth.validate(now: now + 10, macIdentityHash: auth.macIdentityHash))
    }
    func testHandshakeBindsMacAndBothEphemeralKeys() throws {
        let mac = P256.Signing.PrivateKey()
        let phone = P256.KeyAgreement.PrivateKey()
        let server = P256.KeyAgreement.PrivateKey()
        let transcript = try SecureHandshake.transcript(clientKey: phone.publicKey.x963Representation, serverKey: server.publicKey.x963Representation, service: TouchBridgeConstants.serviceUUID)
        let hello = ServerHello(ephemeralKey: server.publicKey.x963Representation, identityKey: mac.publicKey.x963Representation, signature: try mac.signature(for: transcript).derRepresentation)
        XCTAssertNoThrow(try hello.verify(clientKey: phone.publicKey.x963Representation, pinnedIdentity: mac.publicKey.x963Representation, service: TouchBridgeConstants.serviceUUID))
        XCTAssertThrowsError(try hello.verify(clientKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, pinnedIdentity: mac.publicKey.x963Representation, service: TouchBridgeConstants.serviceUUID))
        XCTAssertThrowsError(try hello.verify(clientKey: phone.publicKey.x963Representation, pinnedIdentity: P256.Signing.PrivateKey().publicKey.x963Representation, service: TouchBridgeConstants.serviceUUID))
    }
    func testPairProofBindsTokenKeyAndMetadata() throws {
        let key = P256.Signing.PrivateKey()
        let transcript = Data(repeating: 7, count: 180)
        let proof = try SecureHandshake.possessionBytes(transcript: transcript, deviceID: "device", deviceName: "phone", publicKey: key.publicKey.x963Representation, token: Data(repeating: 1, count: 16))
        let signature = try key.signature(for: proof)
        for changed in [try SecureHandshake.possessionBytes(transcript: transcript, deviceID: "other", deviceName: "phone", publicKey: key.publicKey.x963Representation, token: Data(repeating: 1, count: 16)), try SecureHandshake.possessionBytes(transcript: transcript, deviceID: "device", deviceName: "phone", publicKey: key.publicKey.x963Representation, token: Data(repeating: 2, count: 16))] {
            XCTAssertFalse(key.publicKey.isValidSignature(signature, for: changed))
        }
    }
    func testBoundedMTUFramingAndDowngrade() throws {
        let payload = Data(repeating: 4, count: 3000)
        let frames = try BLEFraming.fragment(payload, mtu: 20, messageID: 99)
        XCTAssertTrue(frames.allSatisfy { $0.count <= 20 })
        var receiver = BLEReassembler()
        var result: Data?
        for frame in frames { result = try receiver.accept(frame, now: 0) }
        XCTAssertEqual(result, payload)
        XCTAssertThrowsError(try receiver.accept(frames[1], now: 1))
        XCTAssertThrowsError(try BLEFraming.fragment(Data(repeating: 0, count: 8193), mtu: 20))
        XCTAssertThrowsError(try WireFormat.decode(data: Data([1, 1, 123, 125])))
        XCTAssertThrowsError(try receiver.accept(Data(repeating: 0, count: 20), now: 1))
    }
}

extension SecurityV2Tests {
    func testCanonicalAllBoundsAndExactReencoding() throws {
        func auth(user: String = "alice", service: String = "sudo", pid: UInt32 = 1, issued: UInt64 = 100, expiry: UInt64 = 110, nonce: Data = Data(repeating: 0, count: 32)) -> AuthorizationPayload {
            AuthorizationPayload(purpose: .pam, nonce: nonce, macIdentityHash: Data(repeating: 0, count: 32), uid: 501, pid: pid, issued: issued, expiry: expiry, user: user, service: service)
        }
        for invalid in [auth(user: ""), auth(user: "a\n"), auth(user: String(repeating: "é", count: 128)), auth(service: ""), auth(service: "sudo /bin/sh"), auth(service: "é"), auth(service: String(repeating: "a", count: 65)), auth(pid: 0), auth(expiry: 100), auth(expiry: 99), auth(expiry: 131), auth(nonce: Data())] { XCTAssertThrowsError(try invalid.encode()) }
        let bytes = try auth().encode()
        for count in 0..<bytes.count { XCTAssertThrowsError(try AuthorizationPayload.parse(Data(bytes.prefix(count)))) }
        var wrongDomain = bytes; wrongDomain[0] = 0; XCTAssertThrowsError(try AuthorizationPayload.parse(wrongDomain))
        var wrongPurpose = bytes; wrongPurpose[9] = 3; XCTAssertThrowsError(try AuthorizationPayload.parse(wrongPurpose))
        var utf8 = bytes; utf8[100] = 0xff; XCTAssertThrowsError(try AuthorizationPayload.parse(utf8))
        XCTAssertThrowsError(try auth().validate(now: 94, macIdentityHash: Data(repeating: 0, count: 32)))
        XCTAssertNoThrow(try auth().validate(now: 95, macIdentityHash: Data(repeating: 0, count: 32)))
    }
    func testFramingRejectsMissingOverlapWrongIDTimeoutAndOverrun() throws {
        let frames = try BLEFraming.fragment(Data(repeating: 1, count: 100), mtu: 30, messageID: 1)
        var receiver = BLEReassembler()
        XCTAssertNil(try receiver.accept(frames[0], now: 0))
        XCTAssertThrowsError(try receiver.accept(frames[0], now: 0))
        XCTAssertNil(try receiver.accept(frames[0], now: 1))
        XCTAssertThrowsError(try receiver.accept(frames[1], now: 7))
        XCTAssertNil(try receiver.accept(frames[0], now: 1))
        XCTAssertThrowsError(try receiver.accept(frames[1], now: 0))
        XCTAssertNil(try receiver.accept(frames[0], now: 1))
        var wrongID = frames[1]; wrongID[6] = 2; XCTAssertThrowsError(try receiver.accept(wrongID, now: 1))
        var tooLarge = frames[0]; tooLarge[7] = 0xff; tooLarge[8] = 0xff; XCTAssertThrowsError(try receiver.accept(tooLarge, now: 1))
        var overrun = frames[0]; overrun[7] = 0; overrun[8] = 1; XCTAssertThrowsError(try receiver.accept(overrun, now: 1))
        XCTAssertThrowsError(try receiver.accept(Data(frames[0].prefix(11)), now: 1))
        XCTAssertThrowsError(try BLEFraming.fragment(Data(), mtu: 20))
        XCTAssertThrowsError(try BLEFraming.fragment(Data([1]), mtu: 11))
        XCTAssertThrowsError(try BLEFraming.fragment(Data([1]), mtu: 65536))
    }
    func testAuthenticatedWireRejectsChangedTypeAndCiphertext() throws {
        let crypto = SessionCrypto(symmetricKey: SymmetricKey(size: .bits256))
        let original = try WireFormat.seal(.error, ErrorMessage(code: 1, description: "x"), crypto: crypto)
        XCTAssertEqual(try WireFormat.open(original, crypto: crypto).type, .error)
        var type = original; type[1] = MessageType.pairResponse.rawValue
        XCTAssertThrowsError(try WireFormat.open(type, crypto: crypto))
        var corrupt = original; corrupt[10] ^= 1
        XCTAssertThrowsError(try WireFormat.open(corrupt, crypto: crypto))
        XCTAssertThrowsError(try WireFormat.open(try WireFormat.encode(.error, ErrorMessage(code: 1, description: "x")), crypto: crypto))
        XCTAssertThrowsError(try SecureHandshake.transcript(clientKey: Data(), serverKey: Data(), service: "bad"))
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        for id in ["", "with space", String(repeating: "a", count: 129)] { XCTAssertThrowsError(try SecureHandshake.possessionBytes(transcript: Data(), deviceID: id, deviceName: "phone", publicKey: key, token: nil)) }
        XCTAssertThrowsError(try SecureHandshake.possessionBytes(transcript: Data(), deviceID: "phone", deviceName: "phone\n", publicKey: key, token: nil))
        XCTAssertThrowsError(try SecureHandshake.possessionBytes(transcript: Data(), deviceID: "phone", deviceName: "phone", publicKey: key, token: Data()))
    }
}

extension SecurityV2Tests {
    func testAcknowledgedBLEWriteHelperNeverUsesATTLongWriteLimit() throws {
        let payload = Data(repeating: 7, count: 600)
        for limits in [(512, 20), (512, 185), (100, 185), (512, 0)] {
            let frames = try BLEFraming.fragmentsForAcknowledgedWrite(payload, maximumWithResponse: limits.0, maximumWithoutResponse: limits.1)
            let maximumSinglePacket = limits.1 > 0 ? min(limits.0, limits.1) : 20
            XCTAssertTrue(frames.allSatisfy { $0.count <= maximumSinglePacket })
            var receiver = BLEReassembler(), output: Data?
            for frame in frames { output = try receiver.accept(frame) }
            XCTAssertEqual(output, payload)
        }
        XCTAssertThrowsError(try BLEFraming.fragmentsForAcknowledgedWrite(payload, maximumWithResponse: 0, maximumWithoutResponse: 20))
    }
}
