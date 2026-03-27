import Foundation

/// Errors during wire format encoding/decoding.
public enum WireFormatError: Error, Sendable {
    case messageTooLarge(Int)
    case messageTooSmall
    case unknownMessageType(UInt8)
    case encodingFailed
    case decodingFailed
}

/// Handles encoding and decoding of TouchBridge wire messages.
///
/// Wire format: [version: UInt8][type: UInt8][payload: JSON bytes]
/// Max total size: 256 bytes.
/// Uses JSON encoding for Phase 0 (MessagePack can be swapped in later).
public struct WireFormat: Sendable {

    private static let headerSize = 2 // version + type

    public static func encode<T: Encodable>(_ type: MessageType, _ message: T) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        let totalSize = headerSize + payload.count
        guard totalSize <= TouchBridgeConstants.maxMessageSize else {
            throw WireFormatError.messageTooLarge(totalSize)
        }

        var data = Data(capacity: totalSize)
        data.append(TouchBridgeConstants.protocolVersion)
        data.append(type.rawValue)
        data.append(payload)
        return data
    }

    public static func decode(data: Data) throws -> (type: MessageType, payload: Data) {
        guard data.count >= headerSize else {
            throw WireFormatError.messageTooSmall
        }

        let typeByte = data[data.startIndex + 1]
        guard let type = MessageType(rawValue: typeByte) else {
            throw WireFormatError.unknownMessageType(typeByte)
        }

        let payload = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        return (type, payload)
    }

    public static func decodePayload<T: Decodable>(_ payloadType: T.Type, from data: Data) throws -> T {
        return try JSONDecoder().decode(payloadType, from: data)
    }
}
