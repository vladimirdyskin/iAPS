import Foundation

/// Status codes returned in `Response[1]`.
/// Spec: docs/smart_bridge_protocol.md §Status codes
public enum SSTAT: UInt8, Sendable {
    case success = 0x00
    case pumpNotResponding = 0x01
    case pumpError = 0x02
    case crcError = 0x03
    case invalidParam = 0x04
    case notConfigured = 0x05
    case busy = 0x06
    case internalError = 0x07
    case timeout = 0x08
}

/// Typed errors thrown from CommandSession / decoders.
public enum SmartBridgeError: Error, Equatable, Sendable {
    case statusError(SSTAT, command: SCMD?)
    case unknownStatus(UInt8)
    case unknownCommand(UInt8)
    case shortPayload(expected: Int, got: Int)
    case malformedResponse(String)
    case timeout
    case notConnected
    case characteristicsMissing
    case versionMismatch(got: String, expected: String)
}

/// Parsed `frag_info` byte.
/// bit7 = MORE_FRAGMENTS, bits[6:0] = fragment_index.
public struct FragmentInfo: Equatable, Sendable {
    public let index: UInt8 // 0..127
    public let moreFragments: Bool

    public init(byte: UInt8) {
        moreFragments = (byte & 0x80) != 0
        index = byte & 0x7F
    }

    public var rawByte: UInt8 {
        (moreFragments ? 0x80 : 0x00) | (index & 0x7F)
    }
}

/// Raw response frame view: `[seq][status][frag_info][payload...]`
public struct ResponseFrame: Equatable, Sendable {
    public let seq: UInt8
    public let status: UInt8
    public let frag: FragmentInfo
    public let payload: Data

    public init?(raw: Data) {
        guard raw.count >= 3 else { return nil }
        let b = [UInt8](raw)
        seq = b[0]
        status = b[1]
        frag = FragmentInfo(byte: b[2])
        payload = raw.count > 3 ? raw.subdata(in: 3 ..< raw.count) : Data()
    }

    public var sstat: SSTAT? { SSTAT(rawValue: status) }
}
