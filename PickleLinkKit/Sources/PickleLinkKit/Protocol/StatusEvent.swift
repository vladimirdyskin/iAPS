import Foundation

/// Status notify channel events. Plugin MUST ignore unknown event_types.
/// Spec: docs/smart_bridge_protocol.md §Status notify channel
public enum StatusEvent: Equatable, Sendable {
    case ready
    /// Device battery low. mV big-endian.
    case batteryLow(deviceMv: UInt16)
    /// Series of pump timeouts. RFM69 raw rssi: -rssi_dbm * 2.
    case radioError(consecutiveErrors: UInt8, lastRssiRaw: UInt8)
    case pumpReachable(lastRssiRaw: UInt8)
    /// Device will reboot in ~1s.
    case watchdogPending
    /// Auto-mmtune changed radio frequency. Hz little-endian.
    case frequencyChanged(hz: UInt32)
    /// Periodic BLE heartbeat (прошивочный status-тик ~2с). Держит iOS-приложение
    /// живым в фоне; транслируется в LoopKit BLE-heartbeat (см. PumpManager).
    case heartbeat
    /// Forward-compat: unknown event_type retained as raw.
    case unknown(eventType: UInt8, data: Data)

    public init?(raw: Data) {
        guard let first = raw.first else { return nil }
        let payload = raw.count > 1 ? raw.subdata(in: 1 ..< raw.count) : Data()
        switch first {
        case 0x01:
            self = .ready
        case 0x02:
            guard let mv = try? EndianRead.u16BE(payload, 0) else { return nil }
            self = .batteryLow(deviceMv: mv)
        case 0x03:
            guard payload.count >= 2 else { return nil }
            let b = [UInt8](payload)
            self = .radioError(consecutiveErrors: b[0], lastRssiRaw: b[1])
        case 0x04:
            guard let b = payload.first else { return nil }
            self = .pumpReachable(lastRssiRaw: b)
        case 0x05:
            self = .watchdogPending
        case 0x06:
            guard let hz = try? EndianRead.u32LE(payload, 0) else { return nil }
            self = .frequencyChanged(hz: hz)
        case 0x07:
            self = .heartbeat
        default:
            self = .unknown(eventType: first, data: payload)
        }
    }
}

/// dBm from RFM69 raw byte.
public extension StatusEvent {
    static func rssiDbm(fromRaw raw: UInt8) -> Int { -Int(raw) / 2 }
}
