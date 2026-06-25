import Foundation

/// High-level API: one method per SCMD.
/// Transport is abstracted via CommandTransport — production wires a `PickleLinkPeripheral`,
/// tests inject a mock.
public actor PickleLinkClient {
    private let session: CommandSession

    // 20с: мост будит помпу перед каждой командой (wakeIfNeeded), worst-case
    // wakeup прошивки ~12.75с (burst + listen PowerAck 12с + long PowerOn) + сама
    // команда. 10с было меньше worst-case wakeup → iOS сдавался раньше прошивки.
    public init(transport: CommandTransport, defaultTimeout: TimeInterval = 20.0) {
        self.session = CommandSession(transport: transport, defaultTimeout: defaultTimeout)
    }

    /// Direct access for transport→session forwarding (BLE peripheral handler calls this).
    public func ingestResponse(_ raw: Data) async {
        await session.handleResponseBytes(raw)
    }

    public func disconnect(error: SmartBridgeError = .notConnected) async {
        await session.failAll(with: error)
    }

    // MARK: - Commands (20)

    /// 0x13 — PING. Returns firmware identity string (`"pickle_smart 1.0"` expected).
    public func ping() async throws -> String {
        try await session.send(.ping, decode: SmartBridgeDecode.ping)
    }

    /// 0x01 — CONFIGURE_PUMP (6 ASCII digits).
    public func configurePump(id: String) async throws {
        _ = try await session.send(.configurePump, params: SCMDParams.configurePump(pumpID: id))
    }

    /// 0x02 — WAKEUP.
    public func wakeup() async throws {
        _ = try await session.send(.wakeup)
    }

    /// 0x03 — GET_MODEL.
    public func getModel() async throws -> UInt16 {
        try await session.send(.getModel, decode: SmartBridgeDecode.model)
    }

    /// 0x04 — GET_BATTERY.
    public func getBattery() async throws -> PumpBattery {
        try await session.send(.getBattery, decode: SmartBridgeDecode.battery)
    }

    /// 0x05 — GET_RESERVOIR.
    public func getReservoir() async throws -> PumpReservoir {
        try await session.send(.getReservoir, decode: SmartBridgeDecode.reservoir)
    }

    /// 0x06 — GET_STATUS.
    public func getStatus() async throws -> PumpStatus {
        try await session.send(.getStatus, decode: SmartBridgeDecode.status)
    }

    /// 0x07 — GET_CLOCK.
    public func getClock() async throws -> Date {
        try await session.send(.getClock, decode: SmartBridgeDecode.clock)
    }

    /// 0x08 — GET_TEMP_BASAL.
    public func getTempBasal() async throws -> TempBasal {
        try await session.send(.getTempBasal, decode: SmartBridgeDecode.tempBasal)
    }

    /// 0x09 — SET_TEMP_BASAL.
    public func setTempBasal(rateMilliunitsPerHour: UInt32, durationMinutes: UInt16) async throws {
        _ = try await session.send(
            .setTempBasal,
            params: SCMDParams.setTempBasal(
                rateMilliunitsPerHour: rateMilliunitsPerHour,
                durationMinutes: durationMinutes
            )
        )
    }

    /// 0x0A — CANCEL_TEMP_BASAL.
    public func cancelTempBasal() async throws {
        _ = try await session.send(.cancelTempBasal)
    }

    /// 0x0B — GET_SETTINGS.
    public func getSettings() async throws -> PumpSettings {
        try await session.send(.getSettings, decode: SmartBridgeDecode.settings)
    }

    /// 0x0C — GET_BASAL_RATES.
    public func getBasalRates() async throws -> [BasalRateEntry] {
        try await session.send(.getBasalRates, decode: SmartBridgeDecode.basalRates)
    }

    /// 0x0D — BOLUS.
    public func bolus(amountMilliunits: UInt32) async throws {
        _ = try await session.send(.bolus, params: SCMDParams.bolus(amountMilliunits: amountMilliunits))
    }

    /// 0x0E — SUSPEND.
    public func suspend() async throws {
        _ = try await session.send(.suspend)
    }

    /// 0x0F — RESUME.
    public func resume() async throws {
        _ = try await session.send(.resume)
    }

    /// 0x10 — GET_HISTORY. Returns raw page bytes (1022 expected for full page).
    /// Longer timeout — fragmentation introduces 20ms inter-fragment delay.
    public func getHistory(page: UInt8, timeout: TimeInterval = 30.0) async throws -> Data {
        try await session.send(
            .getHistory,
            params: SCMDParams.getHistory(page: page),
            timeout: timeout,
            decode: SmartBridgeDecode.historyPage
        )
    }

    /// 0x11 — SET_FREQUENCY.
    public func setFrequency(hz: UInt32) async throws {
        _ = try await session.send(.setFrequency, params: SCMDParams.setFrequency(hz: hz))
    }

    /// 0x12 — GET_STATISTICS.
    public func getStatistics() async throws -> DeviceStatistics {
        try await session.send(.getStatistics, decode: SmartBridgeDecode.statistics)
    }

    /// 0x14 — GET_HISTORY_INFO.
    public func getHistoryInfo() async throws -> HistoryInfo {
        try await session.send(.getHistoryInfo, decode: SmartBridgeDecode.historyInfo)
    }

    /// 0x15 — SET_CLOCK. Синхронизирует часы помпы с локальным временем устройства.
    public func setClock(date: Date = Date()) async throws {
        _ = try await session.send(.setClock, params: SCMDParams.setClock(from: date))
    }

    /// 0x16 — SET_BASAL_SCHEDULE. Пишет расписание базала (макс 48 записей).
    /// Таймаут повышен до 30с — многокадровая запись + wakeup, как getHistory.
    public func setBasalSchedule(
        entries: [(rateMilliunitsPerHour: UInt32, offsetMinutes: UInt16)],
        timeout: TimeInterval = 30.0
    ) async throws {
        _ = try await session.send(
            .setBasalSchedule,
            params: SCMDParams.setBasalSchedule(entries: entries),
            timeout: timeout
        )
    }

    /// 0x17 — SET_MAX_BASAL.
    public func setMaxBasal(rateMilliunitsPerHour: UInt32) async throws {
        _ = try await session.send(.setMaxBasal, params: SCMDParams.setMaxBasal(rateMilliunitsPerHour: rateMilliunitsPerHour))
    }

    /// 0x18 — SET_MAX_BOLUS.
    public func setMaxBolus(amountMilliunits: UInt32) async throws {
        _ = try await session.send(.setMaxBolus, params: SCMDParams.setMaxBolus(amountMilliunits: amountMilliunits))
    }

    /// 0x19 — SET_LED. action: 0=off, 1=on, 2=identify (~2 sec blink).
    public func setLED(action: UInt8) async throws {
        _ = try await session.send(.setLED, params: SCMDParams.setLED(action: action))
    }

    /// 0x1A — GET_LOG. Скачивает диагностический лог моста (фрагментированный, как getHistory).
    /// Возвращает сырой payload (заголовок + записи). Таймаут 30с — фрагментированный ответ.
    public func fetchLog(timeout: TimeInterval = 30.0) async throws -> Data {
        try await session.send(.getLog, timeout: timeout)
    }
}
