import Foundation

// MARK: - Decoded types

public struct PumpBattery: Equatable, Sendable {
    public let millivolts: UInt16
    public init(millivolts: UInt16) { self.millivolts = millivolts }
}

public struct PumpReservoir: Equatable, Sendable {
    public let milliunits: UInt32
    public init(milliunits: UInt32) { self.milliunits = milliunits }
    public var units: Double { Double(milliunits) / 1000.0 }
}

public struct PumpStatus: Equatable, Sendable {
    public let code: UInt8
    public let bolusing: Bool
    public let suspended: Bool
    public init(code: UInt8, bolusing: Bool, suspended: Bool) {
        self.code = code
        self.bolusing = bolusing
        self.suspended = suspended
    }
}

public struct TempBasal: Equatable, Sendable {
    public let rateMilliunitsPerHour: UInt32
    public let minutesRemaining: UInt16
    public init(rateMilliunitsPerHour: UInt32, minutesRemaining: UInt16) {
        self.rateMilliunitsPerHour = rateMilliunitsPerHour
        self.minutesRemaining = minutesRemaining
    }
}

public struct PumpSettings: Equatable, Sendable {
    public let dia: UInt8
    public let tempBasalType: UInt8 // 0=absolute U/hr, 1=percent
    public let maxBasalMu: UInt32
    public let maxBolusMu: UInt32
    public init(dia: UInt8, tempBasalType: UInt8, maxBasalMu: UInt32, maxBolusMu: UInt32) {
        self.dia = dia
        self.tempBasalType = tempBasalType
        self.maxBasalMu = maxBasalMu
        self.maxBolusMu = maxBolusMu
    }
}

public struct BasalRateEntry: Equatable, Sendable {
    public let startSeconds: UInt32
    public let rateMu: UInt32
    public init(startSeconds: UInt32, rateMu: UInt32) {
        self.startSeconds = startSeconds
        self.rateMu = rateMu
    }
}

public struct HistoryInfo: Equatable, Sendable {
    public let currentPage: UInt8
    public let maxPage: UInt8
    public let pageOffset: UInt16
    public init(currentPage: UInt8, maxPage: UInt8, pageOffset: UInt16) {
        self.currentPage = currentPage
        self.maxPage = maxPage
        self.pageOffset = pageOffset
    }
}

public struct DeviceStatistics: Equatable, Sendable {
    public let batteryMv: UInt16
    public let batteryPct: UInt8
    public let rxCount: UInt16
    public let txCount: UInt8
    /// Uptime моста в секундах (u32 BE, offset 6). nil если прошивка < v1.2.0 (6-байт payload).
    public let uptimeSeconds: UInt32?
    public init(batteryMv: UInt16, batteryPct: UInt8, rxCount: UInt16, txCount: UInt8, uptimeSeconds: UInt32? = nil) {
        self.batteryMv = batteryMv
        self.batteryPct = batteryPct
        self.rxCount = rxCount
        self.txCount = txCount
        self.uptimeSeconds = uptimeSeconds
    }
}

// MARK: - Decoders

public enum SmartBridgeDecode {
    /// 0x03 GET_MODEL → uint16 BE
    public static func model(_ p: Data) throws -> UInt16 {
        try EndianRead.u16BE(p, 0)
    }

    /// 0x04 GET_BATTERY
    public static func battery(_ p: Data) throws -> PumpBattery {
        PumpBattery(millivolts: try EndianRead.u16BE(p, 0))
    }

    /// 0x05 GET_RESERVOIR
    public static func reservoir(_ p: Data) throws -> PumpReservoir {
        PumpReservoir(milliunits: try EndianRead.u32BE(p, 0))
    }

    /// 0x06 GET_STATUS
    public static func status(_ p: Data) throws -> PumpStatus {
        guard p.count >= 3 else { throw SmartBridgeError.shortPayload(expected: 3, got: p.count) }
        let b = [UInt8](p)
        return PumpStatus(code: b[0], bolusing: b[1] != 0, suspended: b[2] != 0)
    }

    /// 0x07 GET_CLOCK → Unix timestamp
    public static func clock(_ p: Data) throws -> Date {
        let ts = try EndianRead.u32BE(p, 0)
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    /// 0x08 GET_TEMP_BASAL
    public static func tempBasal(_ p: Data) throws -> TempBasal {
        let rate = try EndianRead.u32BE(p, 0)
        let mins = try EndianRead.u16BE(p, 4)
        return TempBasal(rateMilliunitsPerHour: rate, minutesRemaining: mins)
    }

    /// 0x0B GET_SETTINGS
    public static func settings(_ p: Data) throws -> PumpSettings {
        guard p.count >= 10 else { throw SmartBridgeError.shortPayload(expected: 10, got: p.count) }
        let b = [UInt8](p)
        let maxBasal = try EndianRead.u32BE(p, 2)
        let maxBolus = try EndianRead.u32BE(p, 6)
        return PumpSettings(dia: b[0], tempBasalType: b[1], maxBasalMu: maxBasal, maxBolusMu: maxBolus)
    }

    /// 0x0C GET_BASAL_RATES — array of 8-byte entries.
    public static func basalRates(_ p: Data) throws -> [BasalRateEntry] {
        guard p.count % 8 == 0 else {
            throw SmartBridgeError.malformedResponse("basal rates payload \(p.count) not multiple of 8")
        }
        var out: [BasalRateEntry] = []
        out.reserveCapacity(p.count / 8)
        var off = 0
        while off < p.count {
            let start = try EndianRead.u32BE(p, off)
            let rate = try EndianRead.u32BE(p, off + 4)
            out.append(BasalRateEntry(startSeconds: start, rateMu: rate))
            off += 8
        }
        return out
    }

    /// 0x12 GET_STATISTICS
    /// Payload 6 байт (прошивка < v1.2.0): [batt_hi, batt_lo, batt_pct, rx_hi, rx_lo, tx]
    /// Payload 10 байт (v1.2.0+): как выше + [uptime u32 BE]
    /// Обратная совместимость: 6-байт payload — uptimeSeconds = nil, не является ошибкой.
    public static func statistics(_ p: Data) throws -> DeviceStatistics {
        guard p.count >= 6 else { throw SmartBridgeError.shortPayload(expected: 6, got: p.count) }
        let b = [UInt8](p)
        let mv = try EndianRead.u16BE(p, 0)
        let pct = b[2]
        let rx = try EndianRead.u16BE(p, 3)
        let tx = b[5]
        // Uptime присутствует только в v1.2.0+ (payload >= 10 байт).
        let uptime: UInt32? = p.count >= 10 ? (try? EndianRead.u32BE(p, 6)) : nil
        return DeviceStatistics(batteryMv: mv, batteryPct: pct, rxCount: rx, txCount: tx, uptimeSeconds: uptime)
    }

    /// 0x13 PING → ASCII string
    public static func ping(_ p: Data) throws -> String {
        guard let s = String(data: p, encoding: .ascii) else {
            throw SmartBridgeError.malformedResponse("PING payload not ASCII")
        }
        // Trim trailing NULs/whitespace just in case.
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
    }

    /// 0x14 GET_HISTORY_INFO
    public static func historyInfo(_ p: Data) throws -> HistoryInfo {
        guard p.count >= 4 else { throw SmartBridgeError.shortPayload(expected: 4, got: p.count) }
        let b = [UInt8](p)
        let offset = try EndianRead.u16BE(p, 2)
        return HistoryInfo(currentPage: b[0], maxPage: b[1], pageOffset: offset)
    }

    /// 0x10 GET_HISTORY — opaque (caller forwards bytes to MinimedKit later).
    public static func historyPage(_ p: Data) -> Data { p }
}
