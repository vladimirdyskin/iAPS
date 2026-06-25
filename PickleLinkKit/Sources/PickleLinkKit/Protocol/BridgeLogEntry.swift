import Foundation

// MARK: - Заголовок лога (8 байт LE)

public struct BridgeLogHeader: Sendable {
    /// Общее кол-во записей, что прошивка записала за всё время (может быть > size — кольцо).
    public let total: UInt16
    /// Размер кольцевого буфера (кол-во слотов).
    public let size: UInt16
    /// Индекс «головы» (следующий слот для записи).
    public let head: UInt16
    /// Версия формата (ожидается 2).
    public let version: UInt16
}

// MARK: - Запись (16 байт LE)

public struct BridgeLogEntry: Sendable, Identifiable {
    public let id: Int // порядковый номер записи в payload (старт=0)
    /// Время в мс с момента загрузки прошивки (относительное).
    public let tMs: UInt32
    public let cat: UInt8
    public let code: UInt8
    public let rssi: Int8
    public let flags: UInt8
    public let a: UInt16
    public let b: UInt16
    public let c: UInt32
}

// MARK: - Важность (для цвета в UI)

public enum BridgeLogSeverity: Sendable {
    case normal
    case warning
    case error
}

// MARK: - Декодированная строка для отображения

public struct BridgeLogLine: Sendable, Identifiable {
    public let id: Int
    public let timeStr: String // "12.345s"
    public let text: String
    public let severity: BridgeLogSeverity
}

// MARK: - Парсер payload

public enum BridgeLogDecode {
    private static let headerSize = 8
    private static let entrySize = 16

    /// Парсит весь payload (заголовок + записи), возвращает массив BridgeLogLine.
    /// Записи уже идут старое→новое (прошивка так отдаёт).
    public static func parse(_ payload: Data) throws -> [BridgeLogLine] {
        guard payload.count >= headerSize else {
            throw SmartBridgeError.shortPayload(expected: headerSize, got: payload.count)
        }
        let header = try parseHeader(payload)
        _ = header // используется для проверки версии в будущем
        let body = payload.dropFirst(headerSize)
        guard body.count % entrySize == 0 else {
            throw SmartBridgeError.malformedResponse(
                "bridge log body \(body.count) not multiple of \(entrySize)"
            )
        }
        let bodyData = Data(body)
        let count = bodyData.count / entrySize
        var lines: [BridgeLogLine] = []
        lines.reserveCapacity(count)
        for i in 0 ..< count {
            let entry = try parseEntry(bodyData, index: i)
            lines.append(format(entry))
        }
        return lines
    }

    // MARK: - Внутренние парсеры

    static func parseHeader(_ d: Data) throws -> BridgeLogHeader {
        let total = try EndianRead.u16LE(d, 0)
        let size = try EndianRead.u16LE(d, 2)
        let head = try EndianRead.u16LE(d, 4)
        let version = try EndianRead.u16LE(d, 6)
        return BridgeLogHeader(total: total, size: size, head: head, version: version)
    }

    static func parseEntry(_ d: Data, index: Int) throws -> BridgeLogEntry {
        let off = index * entrySize
        guard d.count >= off + entrySize else {
            throw SmartBridgeError.shortPayload(expected: off + entrySize, got: d.count)
        }
        let b = [UInt8](d)
        let tMs = UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
        let cat = b[off + 4]
        let code = b[off + 5]
        let rssi = Int8(bitPattern: b[off + 6])
        let flags = b[off + 7]
        let a = UInt16(b[off + 8]) | (UInt16(b[off + 9]) << 8)
        let bVal = UInt16(b[off + 10]) | (UInt16(b[off + 11]) << 8)
        let c = UInt32(b[off + 12]) | (UInt32(b[off + 13]) << 8) | (UInt32(b[off + 14]) << 16) | (UInt32(b[off + 15]) << 24)
        return BridgeLogEntry(id: index, tMs: tMs, cat: cat, code: code, rssi: rssi, flags: flags, a: a, b: bVal, c: c)
    }

    // MARK: - Форматирование

    static func format(_ e: BridgeLogEntry) -> BridgeLogLine {
        let timeStr = String(format: "%d.%03ds", e.tMs / 1000, e.tMs % 1000)
        let (text, severity) = describe(e)
        return BridgeLogLine(id: e.id, timeStr: timeStr, text: text, severity: severity)
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func describe(_ e: BridgeLogEntry) -> (String, BridgeLogSeverity) {
        switch e.cat {
        case 1: return describeBLE(e)
        case 2: return describeCMD(e)
        case 3: return describeRADIO(e)
        case 4: return describePUMP(e)
        case 5: return describeSYS(e)
        default:
            return ("cat\(e.cat)/code\(e.code) a=\(e.a) b=\(e.b) c=\(e.c)", .normal)
        }
    }

    private static func describeBLE(_ e: BridgeLogEntry) -> (String, BridgeLogSeverity) {
        switch e.code {
        case 1: return ("BLE CONNECT", .normal)
        case 2:
            let reason = bleDisconnectReason(e.a)
            return ("BLE DISCONNECT reason=\(e.a)\(reason)", .error)
        case 3: return ("BLE NOTIFY_ON", .normal)
        case 4: return ("BLE NOTIFY_OFF", .warning)
        case 5: return ("BLE PARAM_UPDATE interval=\(e.a) supervision=\(e.b)", .normal)
        default: return ("BLE code=\(e.code)", .normal)
        }
    }

    private static func describeCMD(_ e: BridgeLogEntry) -> (String, BridgeLogSeverity) {
        switch e.code {
        case 1:
            let name = scmdName(e.a)
            return ("CMD RX \(name)", .normal)
        case 2:
            let name = scmdName(e.a)
            let stat = sstatName(e.b)
            let ok = e.b == 0
            return ("CMD DONE \(name) → \(stat) (\(e.c)ms)", ok ? .normal : .error)
        case 3:
            let name = scmdName(e.a)
            return ("CMD DROPPED \(name)", .error)
        default:
            return ("CMD code=\(e.code)", .normal)
        }
    }

    private static func describeRADIO(_ e: BridgeLogEntry) -> (String, BridgeLogSeverity) {
        switch e.code {
        case 1:
            let ok = e.a == 1
            return ("RADIO WAKEUP \(ok ? "ACK" : "FAIL") retries=\(e.b) \(e.c)ms", ok ? .normal : .warning)
        case 2:
            return ("RADIO RX len=\(e.b) rssi=\(e.rssi)dBm", .normal)
        case 3:
            return ("RADIO DECODE_FAIL", .error)
        case 4:
            return ("RADIO CRC_FAIL", .error)
        case 5:
            return ("RADIO RX_TIMEOUT consecutive=\(e.a)", e.a > 2 ? .error : .warning)
        case 6:
            return ("RADIO TX cmd=\(e.a)", .normal)
        default:
            return ("RADIO code=\(e.code)", .normal)
        }
    }

    private static func describePUMP(_ e: BridgeLogEntry) -> (String, BridgeLogSeverity) {
        switch e.code {
        case 1: return ("PUMP ACK", .normal)
        case 2: return ("PUMP NAK", .warning)
        case 3: return ("PUMP SILENT", .error)
        default: return ("PUMP code=\(e.code)", .normal)
        }
    }

    private static func describeSYS(_ e: BridgeLogEntry) -> (String, BridgeLogSeverity) {
        switch e.code {
        case 1:
            return ("SYS BOOT reason=\(e.a)", e.a != 0 ? .warning : .normal)
        case 2:
            return ("SYS WATCHDOG errors=\(e.a)", .error)
        case 3:
            return ("SYS RADIO_REINIT", .warning)
        case 4:
            let mhz = String(format: "%.3f", Double(e.c) / 1_000_000)
            return ("SYS FREQ_CHANGE → \(mhz) MHz", .normal)
        case 5:
            return ("SYS HEAP_LOW free=\(e.a)", .error)
        default:
            return ("SYS code=\(e.code)", .normal)
        }
    }

    // MARK: - Вспомогательные справочники

    private static func scmdName(_ raw: UInt16) -> String {
        guard let cmd = SCMD(rawValue: UInt8(raw & 0xFF)) else { return "0x\(String(raw, radix: 16))" }
        switch cmd {
        case .configurePump: return "CONFIGURE_PUMP"
        case .wakeup: return "WAKEUP"
        case .getModel: return "GET_MODEL"
        case .getBattery: return "GET_BATTERY"
        case .getReservoir: return "GET_RESERVOIR"
        case .getStatus: return "GET_STATUS"
        case .getClock: return "GET_CLOCK"
        case .getTempBasal: return "GET_TEMP_BASAL"
        case .setTempBasal: return "SET_TEMP_BASAL"
        case .cancelTempBasal: return "CANCEL_TEMP_BASAL"
        case .getSettings: return "GET_SETTINGS"
        case .getBasalRates: return "GET_BASAL_RATES"
        case .bolus: return "BOLUS"
        case .suspend: return "SUSPEND"
        case .resume: return "RESUME"
        case .getHistory: return "GET_HISTORY"
        case .setFrequency: return "SET_FREQUENCY"
        case .getStatistics: return "GET_STATISTICS"
        case .ping: return "PING"
        case .getHistoryInfo: return "GET_HISTORY_INFO"
        case .setClock: return "SET_CLOCK"
        case .setBasalSchedule: return "SET_BASAL_SCHEDULE"
        case .setMaxBasal: return "SET_MAX_BASAL"
        case .setMaxBolus: return "SET_MAX_BOLUS"
        case .setLED: return "SET_LED"
        case .getLog: return "GET_LOG"
        }
    }

    private static func sstatName(_ raw: UInt16) -> String {
        switch raw {
        case 0: return "OK"
        case 1: return "pumpNotResponding"
        case 2: return "timeout"
        case 3: return "invalidParam"
        case 4: return "notConfigured"
        case 5: return "radioError"
        case 6: return "nak"
        case 7: return "busy"
        default: return "err\(raw)"
        }
    }

    private static func bleDisconnectReason(_ raw: UInt16) -> String {
        switch raw {
        case 8: return " (supervision timeout)"
        case 19: return " (remote terminated)"
        default: return ""
        }
    }
}
