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
    /// Прошивка 1.4.5+: доза МОГЛА быть доставлена (аргументы ушли в эфир, ACK потерян).
    /// НЕ ретраить; фиксировать дозу и сверять с историей (reconciliation).
    case uncertain = 0x09
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

// Человеческие сообщения вместо «SmartBridgeError, ошибка N» (N = порядковый номер
// case). Особенно важно для suspend/resume, которые отдают ошибку сырой (не через
// mapError) — юзер видел загадочную «ошибка 6» вместо понятного текста.
extension SmartBridgeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .statusError(s, _):
            switch s {
            case .success: return nil
            case .pumpNotResponding: return "Помпа не отвечает"
            case .pumpError: return "Помпа отклонила команду"
            case .crcError: return "Ошибка контрольной суммы радио"
            case .invalidParam: return "Неверные параметры команды"
            case .notConfigured: return "Мост не настроен (нет ID помпы)"
            case .busy: return "Мост занят, повтор позже"
            case .internalError: return "Внутренняя ошибка моста"
            case .timeout: return "Таймаут связи с помпой"
            case .uncertain: return "Связь прервана — проверяю по истории"
            }
        case .unknownCommand,
             .unknownStatus: return "Неизвестный ответ моста"
        case .malformedResponse,
             .shortPayload: return "Повреждённый ответ моста"
        case .timeout: return "Мост не ответил вовремя"
        case .notConnected: return "Мост не подключён (переподключение)"
        case .characteristicsMissing: return "Мост не готов к командам"
        case .versionMismatch: return "Несовместимая версия прошивки моста"
        }
    }
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
