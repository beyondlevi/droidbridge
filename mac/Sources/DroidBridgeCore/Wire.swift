import Foundation

/// Wire protocol shared with the Android server (server/src/dev/droidbridge/Protocol.java).
/// Every message is: u8 type, u32 payload length (big-endian), payload.
public enum Wire {
    public static let version: UInt16 = 1
    public static let maxPayload = 1 << 20

    public enum Out: UInt8 {
        case hello = 0x01, enter = 0x02, leave = 0x03, mouse = 0x04, keys = 0x05, clipboard = 0x06, ping = 0x07
    }

    public enum In: UInt8 {
        case device = 0x81, edge = 0x82, clipboard = 0x83, pong = 0x84
    }

    public enum Message: Equatable {
        case device(protocolVersion: UInt16, width: Int, height: Int, model: String)
        case edge(side: Side, ratio: Double)
        case clipboard(String)
        case pong
        case unknown(UInt8)
    }

    public static func frame(_ type: Out, _ payload: [UInt8] = []) -> Data {
        var d = Data([type.rawValue])
        d.append(contentsOf: be32(UInt32(payload.count)))
        d.append(contentsOf: payload)
        return d
    }

    public static func hello() -> Data { frame(.hello, be16(version)) }

    public static func enter(side: Side, ratio: Double) -> Data {
        frame(.enter, [side.rawValue] + be16(ratio16(ratio)))
    }

    public static func leave() -> Data { frame(.leave) }

    public static func mouse(buttons: UInt8, dx: Int, dy: Int, wheel: Int = 0, hwheel: Int = 0) -> Data {
        frame(.mouse, [buttons & 0x1F] + be16(UInt16(bitPattern: Int16(clamping: dx))) + be16(UInt16(bitPattern: Int16(clamping: dy)))
            + [UInt8(bitPattern: Int8(clamping: wheel)), UInt8(bitPattern: Int8(clamping: hwheel))])
    }

    public static func keys(_ report: [UInt8]) -> Data {
        precondition(report.count == 8)
        return frame(.keys, report)
    }

    public static func clipboard(_ text: String) -> Data { frame(.clipboard, Array(text.utf8)) }

    public static func ping() -> Data { frame(.ping) }

    public static func decode(type: UInt8, payload: [UInt8]) -> Message {
        switch In(rawValue: type) {
        case .device where payload.count >= 6:
            return .device(protocolVersion: u16(payload, 0), width: Int(u16(payload, 2)), height: Int(u16(payload, 4)),
                           model: String(decoding: payload[6...], as: UTF8.self))
        case .edge where payload.count >= 3:
            return .edge(side: Side(rawValue: payload[0]) ?? .left, ratio: Double(u16(payload, 1)) / 65535)
        case .clipboard:
            return .clipboard(String(decoding: payload, as: UTF8.self))
        case .pong:
            return .pong
        default:
            return .unknown(type)
        }
    }

    static func ratio16(_ r: Double) -> UInt16 { UInt16((min(max(r, 0), 1) * 65535).rounded()) }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
}

/// A side of the Android screen.
public enum Side: UInt8 {
    case left = 0, right = 1, top = 2, bottom = 3
}

/// Splits a byte stream into messages.
public struct FrameReader {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) throws -> [Wire.Message] {
        buffer.append(contentsOf: bytes)
        var out: [Wire.Message] = []
        while buffer.count >= 5 {
            let length = Int(buffer[1]) << 24 | Int(buffer[2]) << 16 | Int(buffer[3]) << 8 | Int(buffer[4])
            guard length <= Wire.maxPayload else { throw FrameError.tooLarge(length) }
            guard buffer.count >= 5 + length else { break }
            out.append(Wire.decode(type: buffer[0], payload: Array(buffer[5..<(5 + length)])))
            buffer.removeFirst(5 + length)
        }
        return out
    }

    public enum FrameError: Error { case tooLarge(Int) }
}
