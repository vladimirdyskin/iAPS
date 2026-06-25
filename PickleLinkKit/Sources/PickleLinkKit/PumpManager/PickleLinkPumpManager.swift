#if canImport(LoopKit) && canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    import HealthKit
    import LoopKit
    import MinimedKit
    import os.log

    public final class PickleLinkPumpManager: NSObject {
        public static let pluginIdentifier = "PickleLink"

        private let log = OSLog(subsystem: "com.pickle.PickleLinkKit", category: "PumpManager")

        // MARK: - State

        private let lock = NSLock()
        private var lockedState: PickleLinkPumpManagerState

        public private(set) var state: PickleLinkPumpManagerState {
            get { lock.lock()
                defer { lock.unlock() }
                return lockedState }
            set { lock.lock()
                lockedState = newValue
                lock.unlock() }
        }

        private func mutateState(_ changes: (inout PickleLinkPumpManagerState) -> Void) {
            let old = status
            lock.lock()
            changes(&lockedState)
            let snapshot = lockedState
            lock.unlock()
            notifyStateChanged(snapshot, oldStatus: old)
        }

        // MARK: - BLE / transport

        /// Публичный доступ нужен PickleLinkListDataSource (UI) — DataSource использует
        /// этот же менеджер, второй CBCentralManager не создаётся.
        public private(set) var bleManager: PickleLinkBLEManager

        // MARK: Пул мостов (роуминг по нескольким равнозначным мостам одной помпы)

        /// Один подключённый мост: транспорт + сессия + последний RSSI + готовность.
        private final class BridgeLink {
            let id: UUID
            let peripheral: PickleLinkPeripheral
            let client: PickleLinkClient
            var rssi: Int = -127
            var ready = false
            init(_ p: PickleLinkPeripheral) {
                id = p.peripheral.identifier
                peripheral = p
                client = PickleLinkClient(transport: p)
            }
        }

        private let poolLock = NSLock()
        private var bridges: [UUID: BridgeLink] = [:] // все подключённые мосты
        private var activeBridgeID: UUID? // через кого сейчас шлём команды
        private var rssiTimer: DispatchSourceTimer?

        /// Переключаемся на другой мост, только если он сильнее активного на эту
        /// величину (dBm) — антидребезг при близких уровнях. Реактивный фейловер
        /// при обрыве срабатывает всегда, без гистерезиса.
        private let rssiHysteresisDb = 15
        private let rssiPollSeconds = 3

        private let hkDevice: HKDevice

        // MARK: - Delegate plumbing

        private let statusObservers = NSHashTable<AnyObject>.weakObjects()
        private var statusObserverQueues: [ObjectIdentifier: DispatchQueue] = [:]

        private let stateObservers = NSHashTable<AnyObject>.weakObjects()
        private var stateObserverQueues: [ObjectIdentifier: DispatchQueue] = [:]

        private weak var lockedDelegate: PumpManagerDelegate?
        private var lockedDelegateQueue: DispatchQueue?

        // Bolus progress
        private var bolusProgressEstimator: PickleLinkDoseProgressEstimator?

        // MARK: - Init

        public init(state: PickleLinkPumpManagerState) {
            lockedState = state
            bleManager = PickleLinkBLEManager()
            hkDevice = HKDevice(
                name: PickleLinkPumpManager.pluginIdentifier,
                manufacturer: "Medtronic",
                model: state.pumpModel.rawValue,
                hardwareVersion: nil,
                firmwareVersion: nil,
                softwareVersion: nil,
                localIdentifier: state.pumpID,
                udiDeviceIdentifier: nil
            )
            super.init()
            bleManager.delegate = self
            if let id = state.peripheralIdentifier {
                // Помечаем закреплённый мост (дефолт-кандидат, если тогглов нет).
                // НЕ коннектим напрямую — это игнорировало UI-тоггл: закреплённый мост
                // подключался даже выключенным, а включённый оставался резервом.
                // Коннект делает BLEManager.connectAllEnabled (на poweredOn/restore),
                // уважая тогглы (enabledIDs = autoconnectIDs, иначе закреплённый).
                bleManager.markAsPumpPeripheral(id: id)
            }
        }

        public required convenience init?(rawState: PumpManager.RawStateValue) {
            guard let state = PickleLinkPumpManagerState(rawValue: rawState) else { return nil }
            self.init(state: state)
        }

        // MARK: - Status

        public var status: PumpManagerStatus {
            makeStatus(from: state)
        }

        private func makeStatus(from s: PickleLinkPumpManagerState) -> PumpManagerStatus {
            let basal: PumpManagerStatus.BasalDeliveryState
            switch s.suspendState {
            case let .suspended(date):
                basal = .suspended(date)
            case let .resumed(date):
                if let tb = s.unfinalizedTempBasal, !tb.isFinished {
                    basal = .tempBasal(DoseEntry(tb))
                } else {
                    basal = .active(date)
                }
            }
            let bolus: PumpManagerStatus.BolusState
            if let b = s.unfinalizedBolus, !b.isFinished {
                bolus = .inProgress(DoseEntry(b))
            } else {
                bolus = .noBolus
            }
            return PumpManagerStatus(
                timeZone: s.timeZone,
                device: hkDevice,
                pumpBatteryChargeRemaining: s.pumpBatteryChargeRemaining,
                basalDeliveryState: basal,
                bolusState: bolus,
                insulinType: s.insulinType
            )
        }

        private func notifyStateChanged(_ snapshot: PickleLinkPumpManagerState, oldStatus: PumpManagerStatus) {
            let newStatus = makeStatus(from: snapshot)
            delegateQueue?.async { [weak self] in
                guard let self = self else { return }
                self.lockedDelegate?.pumpManagerDidUpdateState(self)
                if newStatus != oldStatus {
                    self.lockedDelegate?.pumpManager(self, didUpdate: newStatus, oldStatus: oldStatus)
                }
            }
            for obj in statusObservers.allObjects {
                guard let observer = obj as? PumpManagerStatusObserver else { continue }
                let q = statusObserverQueues[ObjectIdentifier(obj)] ?? .main
                q.async { observer.pumpManager(self, didUpdate: newStatus, oldStatus: oldStatus) }
            }
            for obj in stateObservers.allObjects {
                guard let observer = obj as? PickleLinkPumpManagerStateObserver else { continue }
                let q = stateObserverQueues[ObjectIdentifier(obj)] ?? .main
                q.async { observer.didUpdatePumpManagerState(snapshot) }
            }
        }

        // MARK: - Client access

        private func requireClient() throws -> PickleLinkClient {
            poolLock.lock()
            defer { poolLock.unlock() }
            if let id = activeBridgeID, let b = bridges[id], b.ready { return b.client }
            // Активный мост пропал — мгновенный фейловер на лучший готовый.
            if let best = bridges.values.filter({ $0.ready }).max(by: { $0.rssi < $1.rssi }) {
                activeBridgeID = best.id
                return best.client
            }
            throw PumpManagerError.connection(nil)
        }

        /// Выбор активного моста: лучший RSSI среди готовых, со сменой только при
        /// превышении гистерезиса (чтобы не дёргалось при близких уровнях).
        private func selectActiveBridge() {
            poolLock.lock()
            defer { poolLock.unlock() }
            let ready = bridges.values.filter { $0.ready }
            guard let best = ready.max(by: { $0.rssi < $1.rssi }) else {
                activeBridgeID = nil
                return
            }
            if let cur = activeBridgeID, let curB = bridges[cur], curB.ready {
                if best.id != cur, best.rssi - curB.rssi >= rssiHysteresisDb {
                    activeBridgeID = best.id
                }
            } else {
                activeBridgeID = best.id
            }
        }

        private func startRSSIPolling() {
            guard rssiTimer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + .seconds(rssiPollSeconds), repeating: .seconds(rssiPollSeconds))
            t.setEventHandler { [weak self] in
                self?.bleManager.updateRSSI() // → didReadRSSI → selectActiveBridge
            }
            t.resume()
            rssiTimer = t
        }

        private func stopRSSIPolling() {
            rssiTimer?.cancel()
            rssiTimer = nil
        }

        /// Diagnostic accessor for the settings UI (0x12 GET_STATISTICS).
        public func fetchStatistics() async throws -> DeviceStatistics {
            try await requireClient().getStatistics()
        }

        /// Diagnostic accessor for the settings UI (0x13 PING).
        public func fetchPing() async throws -> String {
            try await requireClient().ping()
        }

        /// 0x19 SET_LED для активного моста. action: 0=off, 1=on, 2=identify.
        /// Только активный мост — резервный не управляется (requireClient бросит, если нет активного).
        public func setBridgeLED(action: UInt8) async throws {
            try await requireClient().setLED(action: action)
        }

        /// 0x1A GET_LOG — скачивает диагностический лог моста и декодирует в строки.
        public func fetchBridgeLog() async throws -> [BridgeLogLine] {
            let raw = try await requireClient().fetchLog()
            return try BridgeLogDecode.parse(raw)
        }

        /// UUID активного подключённого моста (для определения isConnected в UI).
        public var activeBridgeUUID: UUID? {
            poolLock.lock()
            defer { poolLock.unlock() }
            return activeBridgeID
        }
    }

    // MARK: - Pluggable / DeviceManager

    extension PickleLinkPumpManager: PumpManager {
        public var localizedTitle: String { "PickleLink" }

        public func initializationComplete(for _: [Pluggable]) {}

        public var rawState: PumpManager.RawStateValue { state.rawValue }

        public var isOnboarded: Bool { state.isOnboarded }

        override public var debugDescription: String { state.debugDescription }

        // Alerts (no-op — firmware events surface via logs/state, not LoopKit alerts).
        public func acknowledgeAlert(alertIdentifier _: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
            completion(nil)
        }

        public func getSoundBaseURL() -> URL? { nil }
        public func getSounds() -> [Alert.Sound] { [] }

        // MARK: Capabilities (delegate to MinimedKit PumpModel)

        public static var onboardingMaximumBasalScheduleEntryCount: Int {
            PumpModel.model522.maximumBasalScheduleEntryCount
        }

        public static var onboardingSupportedBasalRates: [Double] {
            PumpModel.model522.supportedBasalRates
        }

        public static var onboardingSupportedBolusVolumes: [Double] {
            PumpModel.model522.supportedBolusVolumes
        }

        public static var onboardingSupportedMaximumBolusVolumes: [Double] {
            onboardingSupportedBolusVolumes
        }

        public var supportedBasalRates: [Double] { state.pumpModel.supportedBasalRates }
        public var supportedBolusVolumes: [Double] { state.pumpModel.supportedBolusVolumes }
        public var supportedMaximumBolusVolumes: [Double] { state.pumpModel.supportedBolusVolumes }
        public var maximumBasalScheduleEntryCount: Int { state.pumpModel.maximumBasalScheduleEntryCount }
        public var minimumBasalScheduleEntryDuration: TimeInterval { state.pumpModel.minimumBasalScheduleEntryDuration }
        public var pumpRecordsBasalProfileStartEvents: Bool { state.pumpModel.recordsBasalProfileStartEvents }
        public var pumpReservoirCapacity: Double { Double(state.pumpModel.reservoirCapacity) }

        public var lastSync: Date? { state.lastRadioErrorAt /* updated on successful pump data refresh */ }

        // MARK: Delegate

        public var pumpManagerDelegate: PumpManagerDelegate? {
            get { lock.lock()
                defer { lock.unlock() }
                return lockedDelegate }
            set { lock.lock()
                lockedDelegate = newValue
                lock.unlock() }
        }

        public var delegateQueue: DispatchQueue! {
            get { lock.lock()
                defer { lock.unlock() }
                return lockedDelegateQueue }
            set { lock.lock()
                lockedDelegateQueue = newValue
                lock.unlock() }
        }

        public func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
            statusObservers.add(observer)
            statusObserverQueues[ObjectIdentifier(observer)] = queue
        }

        public func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
            statusObservers.remove(observer)
            statusObserverQueues[ObjectIdentifier(observer)] = nil
        }

        public func addStateObserver(_ observer: PickleLinkPumpManagerStateObserver, queue: DispatchQueue) {
            stateObservers.add(observer)
            stateObserverQueues[ObjectIdentifier(observer)] = queue
        }

        public func removeStateObserver(_ observer: PickleLinkPumpManagerStateObserver) {
            stateObservers.remove(observer)
            stateObserverQueues[ObjectIdentifier(observer)] = nil
        }

        public func setMustProvideBLEHeartbeat(_: Bool) {}

        // MARK: Bolus

        public func estimatedDuration(toBolus units: Double) -> TimeInterval {
            state.pumpModel.bolusDeliveryTime(units: units)
        }

        public func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter? {
            guard let b = state.unfinalizedBolus, !b.isFinished else { return nil }
            let estimator = PickleLinkDoseProgressEstimator(
                dose: DoseEntry(b),
                pumpModel: state.pumpModel,
                reportingQueue: dispatchQueue
            )
            bolusProgressEstimator = estimator
            return estimator
        }

        public func enactBolus(
            units: Double,
            activationType: BolusActivationType,
            completion: @escaping (PumpManagerError?) -> Void
        ) {
            Task {
                do {
                    let c = try requireClient()
                    let mu = PickleLinkConversions.unitsToMilliunits(units)
                    // Снимок state ДО await — pumpModel/insulinType не должны «уехать».
                    let pumpModel = self.state.pumpModel
                    let insulinType = self.state.insulinType
                    let start = Date()
                    try await c.bolus(amountMilliunits: mu)

                    // Болюс 0x0D принят помпой → НЕМЕДЛЕННО фиксируем дозу. Болюс НЕ
                    // идемпотентен: если не записать, Loop сочтёт его несостоявшимся и
                    // повторит → двойная доза. Подтверждение статусом — best-effort и
                    // НЕ основание считать болюс неудачным (малая доза может пройти
                    // быстрее, чем придёт bolusing=true).
                    let duration = pumpModel.bolusDeliveryTime(units: units)
                    let dose = UnfinalizedDose(
                        bolusAmount: units, startTime: start, duration: duration,
                        insulinType: insulinType,
                        automatic: activationType.isAutomatic
                    )
                    self.mutateState { $0.unfinalizedBolus = dose }
                    completion(nil)
                } catch let e as SmartBridgeError {
                    completion(self.mapError(e))
                } catch {
                    completion(.communication(nil))
                }
            }
        }

        public func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
            // Прерываем болюс через suspend (0x0E) — как MinimedKit cancelBolus:1333.
            // Болюс не идемпотентен: suspend гарантированно останавливает подачу.
            Task {
                do {
                    try await requireClient().suspend() // 0x0E
                    self.mutateState {
                        $0.suspendState = .suspended(Date())
                        $0.unfinalizedBolus = nil
                    }
                    completion(.success(nil))
                } catch {
                    completion(.failure(.communication(nil)))
                }
            }
        }

        // MARK: Temp basal

        public func enactTempBasal(
            unitsPerHour: Double,
            for duration: TimeInterval,
            completion: @escaping (PumpManagerError?) -> Void
        ) {
            Task {
                do {
                    let c = try requireClient()
                    if duration <= 0 {
                        try await c.cancelTempBasal() // 0x0A
                        self.mutateState { $0.unfinalizedTempBasal = nil }
                        completion(nil)
                        return
                    }
                    let rateMu = PickleLinkConversions.unitsToMilliunits(unitsPerHour)
                    let mins = PickleLinkConversions.minutes(from: duration)
                    let start = Date()
                    try await c.setTempBasal(rateMilliunitsPerHour: rateMu, durationMinutes: mins) // 0x09
                    let dose = UnfinalizedDose(
                        tempBasalRate: unitsPerHour, startTime: start,
                        duration: duration, insulinType: self.state.insulinType, automatic: true
                    )
                    self.mutateState { $0.unfinalizedTempBasal = dose }
                    completion(nil)
                } catch let e as SmartBridgeError {
                    completion(self.mapError(e))
                } catch {
                    completion(.communication(nil))
                }
            }
        }

        // MARK: Suspend / Resume

        public func suspendDelivery(completion: @escaping (Error?) -> Void) {
            Task {
                do {
                    try await requireClient().suspend() // 0x0E
                    self.mutateState { $0.suspendState = .suspended(Date()) }
                    completion(nil)
                } catch { completion(error) }
            }
        }

        public func resumeDelivery(completion: @escaping (Error?) -> Void) {
            Task {
                do {
                    try await requireClient().resume() // 0x0F
                    self.mutateState { $0.suspendState = .resumed(Date()) }
                    completion(nil)
                } catch { completion(error) }
            }
        }

        /// Синхронизирует часы помпы с локальным временем устройства (SCMD 0x15).
        public func syncPumpTime(date: Date = Date(), completion: ((Error?) -> Void)? = nil) {
            Task {
                do {
                    try await requireClient().setClock(date: date) // 0x15
                    completion?(nil)
                } catch { completion?(error) }
            }
        }

        // MARK: Pump data refresh

        public func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
            Task {
                do {
                    let c = try requireClient()
                    try? await c.wakeup() // 0x02
                    if let st = try? await c.getStatus() { // 0x06
                        self.mutateState {
                            $0.suspendState = st.suspended ? .suspended(Date()) : .resumed(Date())
                        }
                    }
                    if let battery = try? await c.getBattery() { // 0x04
                        // Щелочная AAA Medtronic: min=1180 mV, max=1470 mV.
                        // Источник: MinimedKit/BatteryChemistryType.swift alkaline
                        // (min=1.18V, max=1.47V) — линейная интерполяция, как в MinimedKit.
                        let pct = max(0.0, min(1.0, (Double(battery.millivolts) - 1180.0) / 290.0))
                        self.mutateState { $0.pumpBatteryChargeRemaining = pct }
                    }
                    if let res = try? await c.getReservoir() { // 0x05
                        self.mutateState { $0.reservoirUnits = res.units }
                        self.reportReservoir(res.units)
                    }
                    try await self.syncHistory() // 0x14 + 0x10
                    completion?(Date())
                } catch {
                    completion?(nil)
                }
            }
        }

        public func syncBasalRateSchedule(
            items: [RepeatingScheduleValue<Double>],
            completion: @escaping (Result<BasalRateSchedule, Error>) -> Void
        ) {
            // 1. Конвертируем LoopKit items → wire entries для SCMD 0x16.
            //    item.startTime — секунды от полуночи (TimeInterval).
            //    item.value    — U/h.
            //    Прошивка ожидает: rate_mU(u32 BE), offset_min(u16 BE).
            let wireEntries = items.map { item -> (rateMilliunitsPerHour: UInt32, offsetMinutes: UInt16) in
                let rateMu = PickleLinkConversions.unitsToMilliunits(item.value)
                let offsetMin = UInt16((item.startTime / 60.0).rounded())
                return (rateMu, offsetMin)
            }

            Task {
                do {
                    let c = try requireClient()

                    // 2. Запись расписания на помпу (0x16).
                    try await c.setBasalSchedule(entries: wireEntries)

                    // 3. Read-back верификация (безопасность — медустройство).
                    //    GET_BASAL_RATES (0x0C) возвращает BasalRateEntry с startSeconds.
                    //    offset_min × 60 должно совпадать с startSeconds.
                    let readback = try await c.getBasalRates() // 0x0C

                    guard readback.count == wireEntries.count else {
                        os_log(
                            "Basal schedule verify FAILED: sent %d entries, got %d back",
                            log: self.log, type: .error,
                            wireEntries.count, readback.count
                        )
                        completion(.failure(PumpManagerError.configuration(nil)))
                        return
                    }

                    for i in readback.indices {
                        let sent = wireEntries[i]
                        let got = readback[i]
                        let expectedSeconds = UInt32(sent.offsetMinutes) * 60
                        let rateDiff = sent.rateMilliunitsPerHour > got.rateMu
                            ? sent.rateMilliunitsPerHour - got.rateMu
                            : got.rateMu - sent.rateMilliunitsPerHour
                        guard got.startSeconds == expectedSeconds, rateDiff <= 1 else {
                            os_log(
                                "Basal schedule verify FAILED at entry %d: sent rate=%d offset=%dmin, got rate=%d start=%ds",
                                log: self.log, type: .error,
                                i, sent.rateMilliunitsPerHour, sent.offsetMinutes,
                                got.rateMu, got.startSeconds
                            )
                            completion(.failure(PumpManagerError.configuration(nil)))
                            return
                        }
                    }

                    // 4. Верификация прошла — формируем расписание из записанных значений.
                    let verifiedItems = items
                    if let schedule = BasalRateSchedule(dailyItems: verifiedItems, timeZone: self.state.timeZone) {
                        // Сохраняем для UI: отображение плановой скорости в SettingsViewModel.
                        self.mutateState { $0.basalSchedule = schedule }
                        completion(.success(schedule))
                    } else {
                        completion(.failure(PumpManagerError.configuration(nil)))
                    }
                } catch { completion(.failure(error)) }
            }
        }

        public func syncDeliveryLimits(
            limits deliveryLimits: DeliveryLimits,
            completion: @escaping (Result<DeliveryLimits, Error>) -> Void
        ) {
            Task {
                do {
                    let c = try requireClient()

                    // maximumBasalRate: HKQuantity в U/h → rate_mU = U/h × 1000 (0x17).
                    if let hkBasal = deliveryLimits.maximumBasalRate {
                        let rateUh = hkBasal.doubleValue(for: HKUnit.internationalUnit().unitDivided(by: .hour()))
                        let rateMu = PickleLinkConversions.unitsToMilliunits(rateUh)
                        try await c.setMaxBasal(rateMilliunitsPerHour: rateMu)
                    }

                    // maximumBolus: HKQuantity в U → amount_mU = U × 1000 (0x18).
                    if let hkBolus = deliveryLimits.maximumBolus {
                        let amountU = hkBolus.doubleValue(for: .internationalUnit())
                        let amountMu = PickleLinkConversions.unitsToMilliunits(amountU)
                        try await c.setMaxBolus(amountMilliunits: amountMu)
                    }

                    completion(.success(deliveryLimits))
                } catch { completion(.failure(error)) }
            }
        }

        public func prepareForDeactivation(_ completion: @escaping (Error?) -> Void) {
            if let id = state.peripheralIdentifier { bleManager.disconnect(id: id) }
            notifyDelegateOfDeactivation { completion(nil) }
        }

        // MARK: - Helpers

        private func reportReservoir(_ units: Double) {
            delegateQueue?.async { [weak self] in
                guard let self = self else { return }
                self.lockedDelegate?.pumpManager(self, didReadReservoirValue: units, at: Date()) { _ in }
            }
        }

        private func syncHistory() async throws {
            let c = try requireClient()
            let filterDate = startDateToFilter()
            let sync = PickleLinkHistorySync(client: c, pumpModel: state.pumpModel, timeZone: state.timeZone)
            let result = try await sync.sync(lastSyncedPage: state.lastSyncedHistoryPage, after: filterDate)
            guard !result.events.isEmpty || result.newLastSyncedPage != state.lastSyncedHistoryPage else { return }
            mutateState { $0.lastSyncedHistoryPage = result.newLastSyncedPage }
            let events = result.events
            delegateQueue?.async { [weak self] in
                guard let self = self else { return }
                self.lockedDelegate?.pumpManager(
                    self,
                    hasNewPumpEvents: events,
                    lastReconciliation: Date(),
                    replacePendingEvents: true
                ) { _ in }
            }
        }

        private func startDateToFilter() -> Date {
            if let q = delegateQueue, let d = lockedDelegate {
                var date = Date().addingTimeInterval(-86400.0)
                q.sync { date = d.startDateToFilterNewPumpEvents(for: self) }
                return date
            }
            return Date().addingTimeInterval(-86400.0)
        }

        private func mapError(_ e: SmartBridgeError) -> PumpManagerError {
            switch e {
            case let .statusError(s, _):
                switch s {
                case .pumpNotResponding,
                     .timeout: return .communication(nil)
                case .invalidParam,
                     .notConfigured: return .configuration(nil)
                default: return .deviceState(nil)
                }
            case .characteristicsMissing,
                 .notConnected: return .connection(nil)
            case .timeout: return .communication(nil)
            default: return .deviceState(nil)
            }
        }
    }

    // MARK: - BLE delegate (transport ↔ client glue)

    extension PickleLinkPumpManager: PickleLinkBLEManagerDelegate, PickleLinkPeripheralDelegate {
        public func bleManager(_: PickleLinkBLEManager, didUpdateState _: CBManagerState) {}

        public func bleManager(_: PickleLinkBLEManager, didUpdateDiscovered devices: [DiscoveredDevice]) {
            NotificationCenter.default.post(
                name: .PickleLinkDiscoveredDevicesDidChange,
                object: self,
                userInfo: ["devices": devices]
            )
        }

        public func bleManager(_: PickleLinkBLEManager, didConnect peripheral: PickleLinkPeripheral) {
            peripheral.delegate = self
            let id = peripheral.peripheral.identifier
            poolLock.lock()
            if bridges[id] == nil { bridges[id] = BridgeLink(peripheral) }
            poolLock.unlock()
        }

        public func bleManager(_: PickleLinkBLEManager, didDisconnect id: UUID, error _: Error?) {
            poolLock.lock()
            let link = bridges.removeValue(forKey: id)
            if activeBridgeID == id { activeBridgeID = nil }
            let empty = bridges.isEmpty
            poolLock.unlock()
            if let link {
                // Провалить зависшую BLE-запись (обрыв в момент записи) — иначе
                // continuation утекает → send() висит → слот команды держится → клин.
                link.peripheral.failPendingWrite()
                let c = link.client
                Task { await c.disconnect() } // failAll: резолвит outstanding-ответы
            }
            selectActiveBridge() // реактивный фейловер на оставшийся мост
            if empty { stopRSSIPolling() }
        }

        public func peripheralIsReady(_ p: PickleLinkPeripheral) {
            let id = p.peripheral.identifier
            // Мост кэширует pump_id в NVS, но теряет его при перепрошивке/сбросе.
            // Источник истины — приложение: переотправляем ConfigurePump (0x01) каждому
            // мосту при готовности (идемпотентно; все мосты настроены на одну помпу).
            let pumpID = state.pumpID
            poolLock.lock()
            let link = bridges[id]
            link?.ready = true
            poolLock.unlock()
            guard let link else { return }
            let c = link.client
            Task { try? await c.configurePump(id: pumpID) }
            selectActiveBridge()
            startRSSIPolling()
        }

        /// The glue the BLE-layer agent intentionally left open:
        /// PickleLinkPeripheral.didReceiveResponse → PickleLinkClient.ingestResponse.
        public func peripheral(_ p: PickleLinkPeripheral, didReceiveResponse data: Data) {
            // Ответ маршрутизируем в сессию ИМЕННО того моста, что его прислал
            // (у каждого свой seq-стол).
            poolLock.lock()
            let c = bridges[p.peripheral.identifier]?.client
            poolLock.unlock()
            if let c { Task { await c.ingestResponse(data) } }
        }

        public func peripheral(_: PickleLinkPeripheral, didReceiveStatusEvent event: StatusEvent) {
            switch event {
            case .ready:
                os_log("Smart Bridge READY", log: log, type: .info)
            case let .batteryLow(mv):
                os_log("Device battery low: %d mV", log: log, type: .info, Int(mv))
            case let .radioError(n, rssi):
                os_log(
                    "RADIO_ERROR x%d rssi=%ddBm",
                    log: log,
                    type: .error,
                    Int(n),
                    StatusEvent.rssiDbm(fromRaw: rssi)
                )
                mutateState { $0.lastRadioErrorAt = Date() }
            case let .pumpReachable(rssi):
                os_log(
                    "Pump reachable rssi=%ddBm",
                    log: log,
                    type: .info,
                    StatusEvent.rssiDbm(fromRaw: rssi)
                )
            case .watchdogPending:
                os_log("WATCHDOG_PENDING", log: log, type: .error)
                mutateState { $0.lastWatchdogAt = Date() }
            case let .frequencyChanged(hz):
                os_log("FREQUENCY_CHANGED → %d Hz", log: log, type: .info, Int(hz))
                mutateState { $0.frequencyHz = hz }
            case .unknown:
                break // forward-compat: ignore unknown events
            }
        }

        public func peripheral(_: PickleLinkPeripheral, didFailWith error: Error) {
            os_log("Peripheral failure: %{public}@", log: log, type: .error, String(describing: error))
        }

        public func peripheral(_ p: PickleLinkPeripheral, didReadRSSI rssi: Int) {
            poolLock.lock()
            bridges[p.peripheral.identifier]?.rssi = rssi
            poolLock.unlock()
            // Обновляем RSSI в discovered (DataSource слушает) и пересчитываем активный мост.
            bleManager.updateDiscoveredRSSI(id: p.peripheral.identifier, rssi: rssi)
            selectActiveBridge()
        }
    }

    // MARK: - State observer protocol

    public protocol PickleLinkPumpManagerStateObserver: AnyObject {
        func didUpdatePumpManagerState(_ state: PickleLinkPumpManagerState)
    }

    // MARK: - Notification names

    public extension Notification.Name {
        /// Постится когда BLEManager обновляет список найденных/подключённых устройств.
        /// userInfo["devices"] = [DiscoveredDevice]
        static let PickleLinkDiscoveredDevicesDidChange = Notification.Name(
            "com.pickle.PickleLinkKit.DiscoveredDevicesDidChange"
        )
    }
#endif
