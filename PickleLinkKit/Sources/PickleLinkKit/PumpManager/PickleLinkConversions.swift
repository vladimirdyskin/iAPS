import Foundation

/// Pure (LoopKit-free) conversion helpers shared by the PumpManager glue.
/// Kept in the core target so they are covered by `swift test`.
public enum PickleLinkConversions {
    /// Insulin: pump/firmware speaks milliunits (1 U = 1000 mU).
    public static func unitsToMilliunits(_ units: Double) -> UInt32 {
        // Round to nearest mU, clamp to UInt32.
        let mu = (units * 1000.0).rounded()
        if mu <= 0 { return 0 }
        if mu >= Double(UInt32.max) { return UInt32.max }
        return UInt32(mu)
    }

    public static func milliunitsToUnits(_ mu: UInt32) -> Double {
        Double(mu) / 1000.0
    }

    /// TimeInterval (seconds) → whole minutes for SET_TEMP_BASAL duration field (UInt16, big-endian).
    public static func minutes(from duration: TimeInterval) -> UInt16 {
        let m = (duration / 60.0).rounded()
        if m <= 0 { return 0 }
        if m >= Double(UInt16.max) { return UInt16.max }
        return UInt16(m)
    }

    /// Maps the firmware GET_MODEL (0x03) 2-byte big-endian value to a Medtronic model
    /// number *string* (e.g. "522") suitable for MinimedKit `PumpModel(rawValue:)`.
    ///
    /// Firmware encoding is the pump's raw 2-byte model id. The low byte selects the
    /// generation family; the high byte selects the reservoir size (5xx vs 7xx).
    /// Per protocol doc example `0x0207 → 522`.
    ///
    /// NOTE: this mapping is best-effort — see integration risks in the report.
    /// Returns nil if unrecognised so the caller can surface a setup error.
    public static func medtronicModelString(fromRaw raw: UInt16) -> String? {
        let low = UInt8(raw & 0x00FF) // generation family
        let high = UInt8((raw >> 8) & 0x00FF) // reservoir-size selector

        // Family digit pair (e.g. 0x07 → "22", 0x05 → "15", 0x23 → "23" already a Veo gen).
        let familySuffix: String
        switch low {
        case 0x08: familySuffix = "08"
        case 0x0B: familySuffix = "11"
        case 0x0C: familySuffix = "12"
        case 0x0F: familySuffix = "15"
        case 0x12: familySuffix = "22"
        case 0x07: familySuffix = "22" // doc example 0x0207 → 522
        case 0x17: familySuffix = "23"
        case 0x1E: familySuffix = "30"
        case 0x28: familySuffix = "40"
        case 0x33: familySuffix = "51"
        case 0x36: familySuffix = "54"
        default: return nil
        }
        // high byte 0x02 → 5xx (small reservoir), 0x03 → 7xx (large reservoir).
        let prefix: String
        switch high {
        case 0x02: prefix = "5"
        case 0x03: prefix = "7"
        default: prefix = "5"
        }
        return prefix + familySuffix
    }
}
