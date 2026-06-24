import Foundation

/// Smart Bridge command opcodes (firmware identity: `pickle_smart 1.0`).
/// Spec: docs/smart_bridge_protocol.md §Commands
public enum SCMD: UInt8, CaseIterable, Sendable {
    case configurePump = 0x01
    case wakeup = 0x02
    case getModel = 0x03
    case getBattery = 0x04
    case getReservoir = 0x05
    case getStatus = 0x06
    case getClock = 0x07
    case getTempBasal = 0x08
    case setTempBasal = 0x09
    case cancelTempBasal = 0x0A
    case getSettings = 0x0B
    case getBasalRates = 0x0C
    case bolus = 0x0D
    case suspend = 0x0E
    case resume = 0x0F
    case getHistory = 0x10
    case setFrequency = 0x11
    case getStatistics = 0x12
    case ping = 0x13
    case getHistoryInfo = 0x14
    case setClock = 0x15
    case setBasalSchedule = 0x16
    case setMaxBasal = 0x17
    case setMaxBolus = 0x18
}

/// Wire frame: `[seq][cmd_id][params...]`
public struct CommandFrame: Sendable, Equatable {
    public let seq: UInt8
    public let command: SCMD
    public let params: Data

    public init(seq: UInt8, command: SCMD, params: Data = Data()) {
        self.seq = seq
        self.command = command
        self.params = params
    }

    public func encode() -> Data {
        var out = Data(capacity: 2 + params.count)
        out.append(seq)
        out.append(command.rawValue)
        out.append(params)
        return out
    }
}

// MARK: - Parameter builders (big-endian per spec, set_frequency LE)

public enum SCMDParams {
    /// 0x01 CONFIGURE_PUMP: 6 ASCII digits.
    public static func configurePump(pumpID: String) -> Data {
        Data(pumpID.utf8)
    }

    /// 0x09 SET_TEMP_BASAL: `[4] rate_mU/h BE [2] duration_min BE`
    public static func setTempBasal(rateMilliunitsPerHour: UInt32, durationMinutes: UInt16) -> Data {
        var d = Data(capacity: 6)
        d.appendBE(rateMilliunitsPerHour)
        d.appendBE(durationMinutes)
        return d
    }

    /// 0x0D BOLUS: `[4] amount_mU BE`
    public static func bolus(amountMilliunits: UInt32) -> Data {
        var d = Data(capacity: 4)
        d.appendBE(amountMilliunits)
        return d
    }

    /// 0x10 GET_HISTORY: `[1] page_index`
    public static func getHistory(page: UInt8) -> Data {
        Data([page])
    }

    /// 0x11 SET_FREQUENCY: `[4] frequency_hz LE`
    public static func setFrequency(hz: UInt32) -> Data {
        var d = Data(capacity: 4)
        d.appendLE(hz)
        return d
    }

    /// 0x16 SET_BASAL_SCHEDULE: `count(u8)` + count×`[rate_mU(u32 BE), offset_min(u16 BE)]`. Макс 48 записей.
    public static func setBasalSchedule(entries: [(rateMilliunitsPerHour: UInt32, offsetMinutes: UInt16)]) -> Data {
        var d = Data(capacity: 1 + entries.count * 6)
        d.append(UInt8(entries.count))
        for e in entries {
            d.appendBE(e.rateMilliunitsPerHour)
            d.appendBE(e.offsetMinutes)
        }
        return d
    }

    /// 0x17 SET_MAX_BASAL: `rate_mU(u32 BE)`.
    public static func setMaxBasal(rateMilliunitsPerHour: UInt32) -> Data {
        var d = Data(capacity: 4)
        d.appendBE(rateMilliunitsPerHour)
        return d
    }

    /// 0x18 SET_MAX_BOLUS: `amount_mU(u32 BE)`.
    public static func setMaxBolus(amountMilliunits: UInt32) -> Data {
        var d = Data(capacity: 4)
        d.appendBE(amountMilliunits)
        return d
    }

    /// 0x15 SET_CLOCK: `[hour][minute][second][year_hi][year_lo][month][day]` — 7 байт.
    /// Порядок подтверждён MinimedKit/ChangeTimeCarelinkMessageBody.swift (cmd 0x40).
    /// Компоненты берутся из локального времени устройства. ЯВНО грегорианский
    /// календарь: у Calendar.current на телефоне может стоять еврейский/буддийский
    /// календарь → год вернётся в чужой системе (5786 вместо 2026) → неверные часы помпы.
    public static func setClock(from date: Date) -> Data {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.hour, .minute, .second, .year, .month, .day], from: date)
        let year = UInt16(comps.year ?? 2000)
        var d = Data(capacity: 7)
        d.append(UInt8(comps.hour ?? 0))
        d.append(UInt8(comps.minute ?? 0))
        d.append(UInt8(comps.second ?? 0))
        d.append(UInt8((year >> 8) & 0xFF)) // year_hi BE
        d.append(UInt8(year & 0xFF)) // year_lo BE
        d.append(UInt8(comps.month ?? 1))
        d.append(UInt8(comps.day ?? 1))
        return d
    }
}

// MARK: - Endian helpers (internal but used by tests / decoders)

extension Data {
    mutating func appendBE(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    mutating func appendBE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }
}

public enum EndianRead {
    public static func u16BE(_ d: Data, _ offset: Int) throws -> UInt16 {
        guard d.count >= offset + 2 else { throw SmartBridgeError.shortPayload(expected: offset + 2, got: d.count) }
        let b = [UInt8](d)
        return (UInt16(b[offset]) << 8) | UInt16(b[offset + 1])
    }

    public static func u32BE(_ d: Data, _ offset: Int) throws -> UInt32 {
        guard d.count >= offset + 4 else { throw SmartBridgeError.shortPayload(expected: offset + 4, got: d.count) }
        let b = [UInt8](d)
        return (UInt32(b[offset]) << 24) | (UInt32(b[offset + 1]) << 16) | (UInt32(b[offset + 2]) << 8) | UInt32(b[offset + 3])
    }

    public static func u32LE(_ d: Data, _ offset: Int) throws -> UInt32 {
        guard d.count >= offset + 4 else { throw SmartBridgeError.shortPayload(expected: offset + 4, got: d.count) }
        let b = [UInt8](d)
        return UInt32(b[offset]) | (UInt32(b[offset + 1]) << 8) | (UInt32(b[offset + 2]) << 16) | (UInt32(b[offset + 3]) << 24)
    }
}
