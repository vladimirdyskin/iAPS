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

    /// Maps the firmware GET_MODEL (0x03) value to a Medtronic model number *string*
    /// (e.g. "722") suitable for MinimedKit `PumpModel(rawValue:)`.
    ///
    /// Прошивка отдаёт номер модели десятичным числом: `pump_model()` парсит
    /// ASCII-ответ помпы ("722") в int 722 и шлёт его как uint16 BE (0x02D2).
    /// PumpModel(rawValue:) ждёт строку номера ("522","722",...), поэтому просто
    /// форматируем число. Валидность проверяет вызывающий через PumpModel(rawValue:).
    public static func medtronicModelString(fromRaw raw: UInt16) -> String? {
        String(raw)
    }
}
