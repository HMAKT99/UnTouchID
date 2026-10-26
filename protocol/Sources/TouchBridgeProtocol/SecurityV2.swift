import Foundation
import CryptoKit

public enum ProtocolSecurityError: Error { case malformed, expired, identityMismatch, invalidProof, revoked }

/// The exact privileged evidence bytes. Never rebuild these from routing hints.
public struct AuthorizationPayload: Equatable, Sendable {
    public enum Purpose: UInt8, Sendable { case pam = 1, diagnostics = 2 }
    public let purpose: Purpose
    public let nonce: Data
    public let macIdentityHash: Data
    public let uid: UInt32
    public let pid: UInt32
    public let issued: UInt64
    public let expiry: UInt64
    public let user: String
    public let service: String
    public init(purpose: Purpose, nonce: Data, macIdentityHash: Data, uid: UInt32, pid: UInt32, issued: UInt64, expiry: UInt64, user: String, service: String) {
        self.purpose = purpose; self.nonce = nonce; self.macIdentityHash = macIdentityHash
        self.uid = uid; self.pid = pid; self.issued = issued; self.expiry = expiry; self.user = user; self.service = service
    }
    public func encode() throws -> Data {
        guard nonce.count == 32, macIdentityHash.count == 32, pid > 0, expiry > issued, expiry - issued <= 30,
              (1...255).contains(user.utf8.count), !user.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (1...64).contains(service.utf8.count), service.utf8.allSatisfy({ Self.serviceByte($0) }) else { throw ProtocolSecurityError.malformed }
        var data = Data("TB-AUTH\0".utf8); data.append(contentsOf: [2, purpose.rawValue]); data.append(nonce); data.append(macIdentityHash)
        data.appendBE(uid); data.appendBE(pid); data.appendBE(issued); data.appendBE(expiry)
        data.appendBE(UInt16(user.utf8.count)); data.append(contentsOf: user.utf8)
        data.appendBE(UInt16(service.utf8.count)); data.append(contentsOf: service.utf8)
        return data
    }
    public static func parse(_ data: Data) throws -> Self {
        var reader = BoundedReader(data)
        guard try reader.take(8) == Data("TB-AUTH\0".utf8), try reader.integer(UInt8.self) == 2,
              let purpose = Purpose(rawValue: try reader.integer(UInt8.self)) else { throw ProtocolSecurityError.malformed }
        let nonce = try reader.take(32), hash = try reader.take(32)
        let uid = try reader.integer(UInt32.self), pid = try reader.integer(UInt32.self)
        let issued = try reader.integer(UInt64.self), expiry = try reader.integer(UInt64.self)
        let userBytes = try reader.take(Int(reader.integer(UInt16.self)))
        let serviceBytes = try reader.take(Int(reader.integer(UInt16.self)))
        guard reader.finished, let user = String(data: userBytes, encoding: .utf8), let service = String(data: serviceBytes, encoding: .utf8) else { throw ProtocolSecurityError.malformed }
        let value = Self(purpose: purpose, nonce: nonce, macIdentityHash: hash, uid: uid, pid: pid, issued: issued, expiry: expiry, user: user, service: service)
        guard try value.encode() == data else { throw ProtocolSecurityError.malformed }; return value
    }
    public func validate(now: UInt64 = UInt64(Date().timeIntervalSince1970), macIdentityHash expected: Data) throws {
        _ = try encode()
        guard macIdentityHash == expected else { throw ProtocolSecurityError.identityMismatch }
        guard issued <= now || issued - now <= 5, expiry > now else { throw ProtocolSecurityError.expired }
    }
    private static func serviceByte(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || [95, 46, 58, 45].contains(b) }
}

public struct ClientHello: Codable, Sendable {
    public let version: UInt8
    public let ephemeralKey: Data
    public init(ephemeralKey: Data) { version = 2; self.ephemeralKey = ephemeralKey }
}
public struct ServerHello: Codable, Sendable {
    public let version: UInt8
    public let ephemeralKey: Data
    public let identityKey: Data
    public let signature: Data
    public init(ephemeralKey: Data, identityKey: Data, signature: Data) { version = 2; self.ephemeralKey = ephemeralKey; self.identityKey = identityKey; self.signature = signature }
    public func verify(clientKey: Data, pinnedIdentity: Data, service: String) throws -> Data {
        guard version == 2, identityKey == pinnedIdentity else { throw ProtocolSecurityError.identityMismatch }
        let transcript = try SecureHandshake.transcript(clientKey: clientKey, serverKey: ephemeralKey, service: service)
        guard try P256.Signing.PublicKey(x963Representation: identityKey).isValidSignature(P256.Signing.ECDSASignature(derRepresentation: signature), for: transcript) else { throw ProtocolSecurityError.invalidProof }
        return transcript
    }
}
public enum SecureHandshake {
    public static func transcript(clientKey: Data, serverKey: Data, service: String) throws -> Data {
        _ = try P256.KeyAgreement.PublicKey(x963Representation: clientKey); _ = try P256.KeyAgreement.PublicKey(x963Representation: serverKey)
        guard let serviceID = UUID(uuidString: service) else { throw ProtocolSecurityError.malformed }
        var bytes = Data("TB-SESSION\0\u{02}".utf8)
        bytes.append(contentsOf: serviceID.uuidString.lowercased().utf8); bytes.append(clientKey); bytes.append(serverKey)
        return bytes
    }
    public static func possessionBytes(transcript: Data, deviceID: String, deviceName: String, publicKey: Data, token: Data?) throws -> Data {
        guard validDeviceID(deviceID), (1...128).contains(deviceName.utf8.count), !deviceName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), token == nil || token?.count == 16 else { throw ProtocolSecurityError.malformed }
        _ = try P256.Signing.PublicKey(x963Representation: publicKey)
        var bytes = Data(token == nil ? "TB-IDENTIFY\0\u{02}".utf8 : "TB-PAIR\0\u{02}".utf8)
        for value in [transcript, Data(deviceID.utf8), Data(deviceName.utf8), publicKey, token ?? Data()] { bytes.appendBE(UInt16(value.count)); bytes.append(value) }
        return bytes
    }
    public static func validDeviceID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [46, 95, 45].contains($0) }
    }
}

extension WireFormat {
    /// Both the message type and all fields are inside authenticated encryption.
    public static func seal<T: Encodable>(_ type: MessageType, _ message: T, crypto: SessionCrypto) throws -> Data {
        let inner = try encode(type, message)
        var bytes = Data([TouchBridgeConstants.protocolVersion, type.rawValue]); bytes.append(try crypto.encrypt(plaintext: inner)); guard bytes.count <= TouchBridgeConstants.maxMessageSize else { throw WireFormatError.messageTooLarge(bytes.count) }; return bytes
    }
    public static func open(_ data: Data, crypto: SessionCrypto) throws -> (type: MessageType, payload: Data) {
        let outer = try decode(data: data)
        let inner = try decode(data: crypto.decrypt(ciphertext: outer.payload))
        guard outer.type == inner.type else { throw ProtocolSecurityError.malformed }; return inner
    }
}

/// Per-characteristic, sequential framing. One incomplete message uses at most 8 KiB.
public enum BLEFraming {
    public static let maximumSize = 8192
    public static let headerSize = 11
    /// The with-response maximum may allow ATT long writes. The no-response
    /// maximum bounds one ATT packet, so every application fragment uses offset 0.
    public static func fragmentsForAcknowledgedWrite(_ data: Data, maximumWithResponse: Int, maximumWithoutResponse: Int) throws -> [Data] {
        let singlePacketLimit = maximumWithoutResponse > 0 ? maximumWithoutResponse : 20
        return try fragment(data, mtu: min(maximumWithResponse, singlePacketLimit, 512))
    }
    public static func fragment(_ data: Data, mtu: Int, messageID: UInt32 = UInt32.random(in: 1...UInt32.max)) throws -> [Data] {
        guard !data.isEmpty, data.count <= maximumSize, mtu > headerSize, mtu <= 65535 else { throw ProtocolSecurityError.malformed }
        var frames: [Data] = []
        for offset in stride(from: 0, to: data.count, by: mtu - headerSize) {
            var frame = Data([0x54, 0x42, 2]); frame.appendBE(messageID); frame.appendBE(UInt16(data.count)); frame.appendBE(UInt16(offset))
            frame.append(data.subdata(in: offset..<min(data.count, offset + mtu - headerSize))); frames.append(frame)
        }
        return frames
    }
}
public struct BLEReassembler {
    private var messageID: UInt32?
    private var size = 0
    private var buffer = Data()
    private var started: TimeInterval = 0
    public init() {}
    public mutating func accept(_ frame: Data, now: TimeInterval = Date().timeIntervalSince1970) throws -> Data? {
        do {
            var reader = BoundedReader(frame)
            guard try reader.take(3) == Data([0x54, 0x42, 2]) else { throw ProtocolSecurityError.malformed }
            let id = try reader.integer(UInt32.self), total = Int(try reader.integer(UInt16.self)), offset = Int(try reader.integer(UInt16.self))
            let chunk = try reader.take(frame.count - BLEFraming.headerSize)
            guard total > 0, total <= BLEFraming.maximumSize, !chunk.isEmpty, offset + chunk.count <= total else { throw ProtocolSecurityError.malformed }
            if messageID == nil { guard offset == 0 else { throw ProtocolSecurityError.malformed }; messageID = id; size = total; started = now }
            guard messageID == id, size == total, offset == buffer.count, now - started <= 5, now >= started else { throw ProtocolSecurityError.malformed }
            buffer.append(chunk)
            if buffer.count == total { let data = buffer; self = Self(); return data }; return nil
        } catch { self = Self(); throw error }
    }
}
private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) { for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) { append(UInt8(truncatingIfNeeded: value >> shift)) } }
}
private struct BoundedReader {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = data }
    var finished: Bool { offset == data.count }
    mutating func take(_ count: Int) throws -> Data { guard count >= 0, count <= data.count - offset else { throw ProtocolSecurityError.malformed }; defer { offset += count }; return data.subdata(in: offset..<offset + count) }
    mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T { var value: T = 0; for byte in try take(MemoryLayout<T>.size) { value = (value << 8) | T(byte) }; return value }
}
