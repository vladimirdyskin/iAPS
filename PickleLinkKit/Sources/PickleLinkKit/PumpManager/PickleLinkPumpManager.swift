#if canImport(LoopKit) && canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    import HealthKit
    import LoopKit
    // MinimedKit не импортируется: PumpModel, SuspendState, UnfinalizedDose — in-module (Medtronic/)
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

        // Connect-watchdog: если после BLE-коннекта GATT не поднялся (peripheralIsReady не
        // пришёл) за 12с — форсируем разрыв, чтобы BLEManager обнулил activeID и переставил
        // pending-коннект. Иначе полу-коннект (краевой сигнал при возврате в зону) держит
        // activeID занятым: реконнект заблокирован, а команды не идут → клин. Доступ с main
        // (BLE-колбэки идут на main-очередь CBCentralManager).
        private var connectWatchdogs: [UUID: DispatchWorkItem] = [:]

        private func scheduleReadyWatchdog(_ id: UUID) {
            connectWatchdogs[id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.connectWatchdogs[id] = nil
                poolLock.lock()
                let ready = bridges[id]?.ready ?? false
                poolLock.unlock()
                guard !ready else { return }
                os_log(
                    "Connect watchdog: %{public}@ not ready in 12s → force reconnect",
                    log: self.log, type: .error, id.uuidString
                )
                self.bleManager.disconnect(id: id) // cancel → didDisconnect → activeID=nil → pending
            }
            connectWatchdogs[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
        }

        private func cancelReadyWatchdog(_ id: UUID) {
            connectWatchdogs[id]?.cancel()
            connectWatchdogs[id] = nil
        }

        // BLE-heartbeat (LoopKit): см. setMustProvideBLEHeartbeat/maybeFireBLEHeartbeat.
        private let heartbeatLock = NSLock()
        private var mustProvideBLEHeartbeat = false
        private var lastHeartbeatFire: Date?

        // Гейт свежести данных помпы (аудит R3, зеркало Minimed isPumpDataStale):
        // не гонять полный RF-опрос чаще, чем раз в 4 мин (CGM-тик может быть 1-мин).
        private let refreshLock = NSLock()
        private var lastPumpDataRefresh: Date?

        // Одиночный бэкафилл (аудит B7): параллельные 16-страничные проходы
        // забивают радио и морят голодом команды дозирования.
        private var backfillInProgress = false

        // Троттл автосинка часов: SET_CLOCK — long-команда, на слабом радио стабильно
        // падает (DECODE_FAIL). Без троттла попытка идёт каждые 4 мин (staleness-гейт),
        // засоряя лог. Пытаемся не чаще раза в час — этого хватает против дрейфа
        // reconcile-окна, а спам на плохом радио убирает.
        private var lastClockSyncAttempt: Date?

        // Синхронные обёртки над refreshLock (голый lock()/unlock() недоступен из async —
        // зовём эти хелперы из Task, лок берётся в синхронном контексте).
        private func readLastPumpDataRefresh() -> Date? {
            refreshLock.lock()
            defer { refreshLock.unlock() }
            return lastPumpDataRefresh
        }

        private func markPumpDataRefreshed() {
            refreshLock.lock()
            lastPumpDataRefresh = Date()
            refreshLock.unlock()
        }

        /// Пытается захватить single-flight-слот бэкафилла. true — слот наш (вызвать
        /// endBackfill в конце); false — бэкафилл уже идёт, выходим.
        private func beginBackfill() -> Bool {
            refreshLock.lock()
            defer { refreshLock.unlock() }
            if backfillInProgress { return false }
            backfillInProgress = true
            return true
        }

        private func endBackfill() {
            refreshLock.lock()
            backfillInProgress = false
            refreshLock.unlock()
        }

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
                // Помечаем закреплённый мост. markAsPumpPeripheral ОДИН раз засевает его
                // в autoconnect (тоггл ON по умолчанию), дальше тоггл — единственный
                // источник истины. НЕ коннектим напрямую. Коннект делает
                // BLEManager.connectAllEnabled (на poweredOn/restore), строго по тогглам
                // (enabledIDs = autoconnectIDs).
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

        /// Тип инсулина — публичный сеттер для UI (зеркало MinimedPumpManager.insulinType ~1019).
        public var insulinType: InsulinType? {
            get { state.insulinType }
            set { mutateState { $0.insulinType = newValue } }
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

        // BLE-heartbeat (LoopKit): iAPS требует периодический «пульс», чтобы лупиться
        // в фоне, когда нет другого BLE-источника (pumpManagerMustProvideBLEHeartbeat).
        // Прошивка шлёт status-тик каждые ~2с — транслируем его в
        // pumpManagerBLEHeartbeatDidFire, но НЕ чаще раза в 60с (heartbeat() в iAPS
        // запускает оценку петли — это дорого). Без этого iAPS не держит коннект в
        // фоне → iOS забирает линк после фонового окна (reason 19).
        // (Хранимые поля heartbeatLock/mustProvideBLEHeartbeat/lastHeartbeatFire — в теле класса.)
        public func setMustProvideBLEHeartbeat(_ flag: Bool) {
            heartbeatLock.lock()
            mustProvideBLEHeartbeat = flag
            heartbeatLock.unlock()
        }

        private func maybeFireBLEHeartbeat() {
            heartbeatLock.lock()
            let now = Date()
            let due = mustProvideBLEHeartbeat &&
                (lastHeartbeatFire.map { now.timeIntervalSince($0) >= 60 } ?? true)
            if due { lastHeartbeatFire = now }
            heartbeatLock.unlock()
            guard due else { return }
            // pumpManagerBLEHeartbeatDidFire требует processQueue (== delegateQueue).
            delegateQueue?.async { [weak self] in
                guard let self else { return }
                self.lockedDelegate?.pumpManagerBLEHeartbeatDidFire(self)
            }
        }

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
                let c: PickleLinkClient
                do { c = try requireClient() }
                catch { completion(.connection(nil))
                    return }

                let mu = PickleLinkConversions.unitsToMilliunits(units)
                // Снимок state ДО await — pumpModel/insulinType не должны «уехать».
                let pumpModel = self.state.pumpModel
                let insulinType = self.state.insulinType

                // Гард (аудит C4, зеркало MinimedKit ~1264-1274): предыдущий болюс ещё
                // КАПАЕТ → отказ. Без гарда гонка двух enactBolus (SMB vs ручной) через
                // параллельный reconcile теряла дозу из state → двойной учёт от истории.
                // ЗАВЕРШЁННЫЙ прежний болюс архивируем в pendingDoses (ждёт reconcile).
                var previousInProgress = false
                self.mutateState { s in
                    if let prev = s.unfinalizedBolus {
                        if prev.isFinished {
                            s.pendingDoses.append(prev)
                            s.unfinalizedBolus = nil
                        } else {
                            previousInProgress = true
                        }
                    }
                }
                guard !previousInProgress else {
                    completion(.deviceState(nil)) // bolus in progress
                    return
                }

                let duration = pumpModel.bolusDeliveryTime(units: units)

                do {
                    try await c.bolus(amountMilliunits: mu)
                    // Успех → фиксируем дозу. startTime = СЕЙЧАС (после подтверждения):
                    // wakeup мог съесть до ~15с, ранний start завышал прогресс и съедал
                    // запас reconcile-окна (аудит MINOR).
                    let dose = UnfinalizedDose(
                        bolusAmount: units, startTime: Date(), duration: duration,
                        insulinType: insulinType,
                        automatic: activationType.isAutomatic
                    )
                    self.mutateState { $0.unfinalizedBolus = dose }
                    completion(nil)
                } catch {
                    // КРИТИЧНО против двойной дозы. Болюс НЕ идемпотентен и мог УЖЕ пройти на
                    // помпе, даже если ответ моста потерян (обрыв BLE / битый ACK / timeout).
                    if self.bolusDefinitelyNotDelivered(error) {
                        // Мост/помпа отвергли ДО подачи (invalidParam/notConfigured/NAK-rewind)
                        // → доза ТОЧНО не начиналась → НЕ пишем, сообщаем ошибку.
                        completion((error as? SmartBridgeError).map(self.mapError) ?? .communication(nil))
                    } else {
                        // НЕОПРЕДЕЛЁННОСТЬ (timeout/обрыв/pumpNotResponding/SSTAT_UNCERTAIN):
                        // болюс мог пройти → ФИКСИРУЕМ дозу и возвращаем успех. Так IOB
                        // учитывает её сразу → oref НЕ порекомендует повтор. Если болюс на
                        // деле не прошёл — фантом уйдёт из state по reconcile (переучёт
                        // безопаснее двойной дозы).
                        let dose = UnfinalizedDose(
                            bolusAmount: units, startTime: Date(), duration: duration,
                            insulinType: insulinType,
                            automatic: activationType.isAutomatic
                        )
                        self.mutateState { $0.unfinalizedBolus = dose }
                        os_log(
                            "Bolus UNCERTAIN (%{public}@) — recorded to prevent double-dose",
                            log: self.log, type: .error, String(describing: error)
                        )
                        completion(nil)
                    }
                }
            }
        }

        /// Ошибка болюса, при которой доза ТОЧНО не доставлена (отказ ДО физической подачи):
        /// invalidParam/notConfigured — мост отверг до радио; pumpError — помпа явно
        /// отвергла (NAK: rewind/suspend); busy — очередь моста полна, команда не принята
        /// (аудит B5); SSTAT timeout — TTL-drop из очереди 1.4.5 (протухла ДО исполнения);
        /// SSTAT internalError — мёртвое радио 1.4.5 (отказ до dispatch);
        /// characteristicsMissing — GATT-записи не было.
        /// НЕОПРЕДЕЛЁННОСТЬ (дозу фиксируем — защита от двойной дозы): client-side
        /// .timeout (ответ мог потеряться ПОСЛЕ исполнения!), обрыв, SSTAT_UNCERTAIN 0x09,
        /// pumpNotResponding — НАМЕРЕННО uncertain: на прошивке <1.4.5 (второй мост!)
        /// этот статус покрывал и фазу-2 (доза ушла) — фантом безопаснее двойной дозы.
        private func bolusDefinitelyNotDelivered(_ error: Error) -> Bool {
            guard let e = error as? SmartBridgeError else { return false }
            switch e {
            case let .statusError(s, _):
                return s == .invalidParam || s == .notConfigured || s == .pumpError || s == .busy
                    || s == .timeout || s == .internalError
            case .characteristicsMissing:
                return true
            default:
                return false
            }
        }

        public func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
            // Прерываем болюс через suspend (0x0E) — как MinimedKit cancelBolus:1333.
            // Болюс не идемпотентен: suspend гарантированно останавливает подачу.
            // Аудит C1 (зеркало Minimed runSuspendResumeOnSession 333-356): фиксируем
            // ДОСТАВЛЕННУЮ часть дозы (cancel(at:) пересчитывает units по прогрессу),
            // переносим в pendingDoses (для reconcile с историей — иначе history-событие
            // задвоит IOB), пишем suspend-дозу (oref должен знать, что базал остановлен).
            Task {
                do {
                    try await requireClient().suspend() // 0x0E
                    let now = Date()
                    var canceledEntry: DoseEntry?
                    self.mutateState { s in
                        s.suspendState = .suspended(now)
                        if var b = s.unfinalizedBolus {
                            b.cancel(at: now, pumpModel: s.pumpModel)
                            s.pendingDoses.append(b)
                            canceledEntry = DoseEntry(b)
                            s.unfinalizedBolus = nil
                        }
                        s.pendingDoses.append(UnfinalizedDose(suspendStartTime: now))
                    }
                    self.reportPendingDoses() // немедленно в IOB, не ждём syncHistory
                    completion(.success(canceledEntry))
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
                        // Прежний незавершённый темп НЕ обнуляем молча (аудит B4, зеркало
                        // Minimed 1390-1392): укорачиваем по факту отмены и переносим в
                        // pendingDoses — иначе доставленная часть темпа теряется из IOB.
                        let now = Date()
                        self.mutateState { s in
                            if var prev = s.unfinalizedTempBasal {
                                prev.cancel(at: now, pumpModel: s.pumpModel)
                                s.pendingDoses.append(prev)
                            }
                            s.unfinalizedTempBasal = nil
                        }
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
                    self.mutateState { s in
                        // Успешный новый темп ⇒ помпа не suspended (аудит B4, зеркало
                        // Minimed 1381-1386).
                        s.suspendState = .resumed(start)
                        // Прежний незавершённый темп переносим в pendingDoses (тот же
                        // перенос, что и в ветке отмены) — не затираем его новым.
                        if var prev = s.unfinalizedTempBasal {
                            prev.cancel(at: start, pumpModel: s.pumpModel)
                            s.pendingDoses.append(prev)
                        }
                        s.unfinalizedTempBasal = dose
                    }
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
                    // Аудит B2 (зеркало Minimed runSuspendResumeOnSession 333-356):
                    // фиксируем доставленную часть болюса, переносим в pendingDoses (для
                    // reconcile с историей), пишем suspend-дозу. oref должен увидеть
                    // остановку базала СРАЗУ, не дожидаясь истории.
                    let now = Date()
                    self.mutateState { s in
                        s.suspendState = .suspended(now)
                        if var b = s.unfinalizedBolus {
                            b.cancel(at: now, pumpModel: s.pumpModel)
                            s.pendingDoses.append(b)
                            s.unfinalizedBolus = nil
                        }
                        s.pendingDoses.append(UnfinalizedDose(suspendStartTime: now))
                    }
                    self.reportPendingDoses()
                    completion(nil)
                } catch { completion(error) }
            }
        }

        public func resumeDelivery(completion: @escaping (Error?) -> Void) {
            Task {
                do {
                    try await requireClient().resume() // 0x0F
                    // Аудит B2 (зеркало Minimed 352-354): пишем resume-дозу, чтобы oref
                    // увидел возобновление базала сразу. resumeStartTime-init требует тип
                    // инсулина — без него дозу не создаём (базал возобновится по истории).
                    let now = Date()
                    self.mutateState { s in
                        s.suspendState = .resumed(now)
                        if let it = s.insulinType {
                            s.pendingDoses.append(UnfinalizedDose(resumeStartTime: now, insulinType: it))
                        }
                    }
                    self.reportPendingDoses()
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
                // Гейт свежести (аудит R3, зеркало Minimed isPumpDataStale): CGM-тик может
                // быть 1-мин, но полный RF-опрос помпы дорог и глушит радио. Если данные
                // свежее 4 мин — отдаём кэш, RF не гоняем.
                let last = readLastPumpDataRefresh()
                if let last, Date().timeIntervalSince(last) < 240 {
                    completion?(last)
                    return
                }
                do {
                    let c = try requireClient()
                    try? await c.wakeup() // 0x02
                    // Автосинк часов помпы (аудит C2 — КРИТИЧНО): reconcile сверяет
                    // pending-дозы с историей в окне ±60с (firstMatchingIndex). Дрейф часов
                    // помпы сдвигает временны́е метки истории → доза не матчится → двойной
                    // учёт. Правим, если разошлись больше 20с.
                    // Троттл: пытаемся синкать не чаще раза в час (SET_CLOCK на слабом
                    // радио стабильно падает и засоряет лог — см. lastClockSyncAttempt).
                    let clockDue: Bool = {
                        refreshLock.lock()
                        defer { refreshLock.unlock() }
                        guard let last = lastClockSyncAttempt else { return true }
                        return Date().timeIntervalSince(last) > 3600
                    }()
                    if clockDue, let pumpClock = try? await c.getClock() { // 0x07
                        let drift = pumpClock.timeIntervalSinceNow
                        if abs(drift) > 20 {
                            refreshLock.lock()
                            lastClockSyncAttempt = Date()
                            refreshLock.unlock()
                            try? await c.setClock() // 0x15
                            os_log(
                                "Pump clock drift %{public}.1fs > 20s — resync attempt",
                                log: self.log, type: .info, drift
                            )
                        }
                    }
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
                    // Читаем расписание базала один раз — если ещё не загружено (экономия RF).
                    // После syncBasalRateSchedule оно уже есть в state и не перечитывается.
                    if self.state.basalSchedule == nil {
                        if let entries = try? await c.getBasalRates(), !entries.isEmpty { // 0x0C
                            let items = entries.map { entry in
                                RepeatingScheduleValue<Double>(
                                    startTime: TimeInterval(entry.startSeconds),
                                    value: PickleLinkConversions.milliunitsToUnits(entry.rateMu)
                                )
                            }
                            if let schedule = BasalRateSchedule(dailyItems: items, timeZone: self.state.timeZone) {
                                self.mutateState { $0.basalSchedule = schedule }
                            }
                        }
                    }
                    try await self.syncHistory() // 0x14 + 0x10
                    // Успешный полный опрос — обновляем метку свежести (гейт R3 выше).
                    markPumpDataRefreshed()
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
            // Аудит B1: чистим сид автоконнекта ДО disconnect. Иначе протухший
            // autoconnect/seeded-ключ переживает удаление помпы и блокирует подключение
            // нового моста после переустановки (markAsPumpPeripheral не пересевает).
            bleManager.clearAutoconnectState()
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

        /// Немедленно публикует ВСЕ pending-дозы (suspend/resume/cancel/болюс/темп) в Loop,
        /// не дожидаясь прохода истории (зеркало MinimedPumpManager.storePendingPumpEvents ~846).
        /// Нужно, чтобы oref увидел остановку/возобновление подачи сразу — история по слабому
        /// радио может дойти позже. replacePendingEvents: true — pending-события идемпотентны.
        private func reportPendingDoses() {
            let events = (state.pendingDoses + [state.unfinalizedBolus, state.unfinalizedTempBasal])
                .compactMap { $0?.newPumpEvent() }
            delegateQueue?.async { [weak self] in
                guard let self = self else { return }
                self.lockedDelegate?.pumpManager(
                    self,
                    hasNewPumpEvents: events,
                    lastReconciliation: self.state.lastReconciliation,
                    replacePendingEvents: true
                ) { _ in }
            }
        }

        private func syncHistory() async throws {
            let c = try requireClient()
            let filterDate = startDateToFilter()
            let sync = PickleLinkHistorySync(client: c, pumpModel: state.pumpModel, timeZone: state.timeZone)
            let result = try await sync.sync(lastSyncedPage: state.lastSyncedHistoryPage, after: filterDate)
            guard !result.events.isEmpty || result.newLastSyncedPage != state.lastSyncedHistoryPage else {
                // Новых событий нет, но бэкафилл всё равно нужен если не выполнялся.
                if !state.backfillDone {
                    Task { [weak self] in await self?.backfillEventDates() }
                }
                return
            }
            mutateState { $0.lastSyncedHistoryPage = result.newLastSyncedPage }

            // Обновляем даты смены резервуара и набора (зеркало MinimedPumpManager.updateLastEventDates).
            updateLastEventDates(from: result.events)

            // Бэкафилл: одноразовый глубокий поиск rewind/setChange без фильтра по дате.
            // Запускаем в отдельном Task чтобы не блокировать поллинг — RF-дорогая операция.
            if !state.backfillDone {
                Task { [weak self] in await self?.backfillEventDates() }
            }

            // Аннотируем дозы типом инсулина (зеркало MinimedPumpManager ~стр. 760-766).
            let insulinType = state.insulinType
            let annotated: [NewPumpEvent] = result.events.map { event in
                guard let insulinType else { return event }
                return NewPumpEvent(
                    date: event.date,
                    dose: event.dose?.annotated(with: insulinType),
                    raw: event.raw,
                    title: event.title,
                    type: event.type
                )
            }

            // Согласование pending-доз с историей (зеркало MinimedKit reconcilePendingDosesWith).
            // КРИТИЧНО против двойной дозы: pending-болюс попадает в IOB НЕМЕДЛЕННО (не ждёт,
            // пока история дойдёт по слабому радио) → oref не порекомендует повтор. Появившись
            // в истории — схлопывается (нет дубля); зависший фантом — удаляется.
            let fetchedAt = Date()
            let remainingEvents = reconcilePendingDoses(with: annotated, fetchedAt: fetchedAt)

            // Отчёт в Loop: события истории (без схлопнутых) + ВСЕ pending как события.
            let pendingEvents = (state.pendingDoses + [state.unfinalizedTempBasal, state.unfinalizedBolus])
                .compactMap { $0?.newPumpEvent() }
            // Сортировка по date ВОЗРАСТАНИЮ (аудит R4): iAPS берёт lastEventDate =
            // events.last?.date. pending-хвост (склеен после history) может держать более
            // СТАРУЮ дату → откат lastEventDate → фильтр застревает, каждый цикл качает всё.
            let reportEvents = (remainingEvents + pendingEvents).sorted { $0.date < $1.date }

            delegateQueue?.async { [weak self] in
                guard let self = self else { return }
                self.lockedDelegate?.pumpManager(
                    self,
                    hasNewPumpEvents: reportEvents,
                    lastReconciliation: self.state.lastReconciliation,
                    replacePendingEvents: true
                ) { error in
                    guard error == nil else { return }
                    // Чистим pending, согласованные с историей И завершённые (зеркало Minimed ~784).
                    self.mutateState { s in
                        if let b = s.unfinalizedBolus, b.isReconciledWithHistory, b.isFinished { s.unfinalizedBolus = nil }
                        if let t = s.unfinalizedTempBasal, t.isReconciledWithHistory,
                           t.isFinished { s.unfinalizedTempBasal = nil }
                        s.pendingDoses.removeAll { $0.isReconciledWithHistory && $0.isFinished }
                    }
                }
            }
        }

        /// Согласование (dedup) pending-доз с событиями истории — точное зеркало
        /// MinimedPumpManager.reconcilePendingDosesWith (static). Матчит по временно́му окну,
        /// строит mapping event.raw→доза, помечает дозу reconciled.
        private static func reconcilePendingDosesWith(
            _ events: [NewPumpEvent],
            reconciliationMappings: [Data: ReconciledDoseMapping],
            pendingDoses: [UnfinalizedDose]
        )
            -> (
                remainingEvents: [NewPumpEvent],
                reconciliationMappings: [Data: ReconciledDoseMapping],
                pendingDoses: [UnfinalizedDose]
            )
        {
            var newMapping = reconciliationMappings
            var reconcilable = events.filter { !newMapping.keys.contains($0.raw) }
            let matchingWindow = TimeInterval(minutes: 1)

            let allPending = pendingDoses.map { dose -> UnfinalizedDose in
                if let index = reconcilable.firstMatchingIndex(for: dose, within: matchingWindow) {
                    let historyEvent = reconcilable[index]
                    newMapping[historyEvent.raw] = ReconciledDoseMapping(
                        startTime: dose.startTime, uuid: dose.uuid, eventRaw: historyEvent.raw
                    )
                    var reconciled = dose
                    reconciled.reconcile(with: historyEvent)
                    reconcilable.remove(at: index)
                    return reconciled
                }
                return dose
            }
            let remaining = events.filter { newMapping[$0.raw] == nil }
            return (remaining, newMapping, allPending)
        }

        /// Instance-обёртка: согласует unfinalizedBolus/Temp + pendingDoses с историей,
        /// раскладывает результат обратно по слотам, чистит зависшие/протухшие. Зеркало
        /// MinimedPumpManager.reconcilePendingDosesWith (instance ~665). Возвращает события
        /// истории без схлопнутых с pending.
        private func reconcilePendingDoses(with events: [NewPumpEvent], fetchedAt: Date) -> [NewPumpEvent] {
            var remaining: [NewPumpEvent] = events
            mutateState { state in
                let allPending = (state.pendingDoses + [state.unfinalizedTempBasal, state.unfinalizedBolus]).compactMap { $0 }
                let r = Self.reconcilePendingDosesWith(
                    events, reconciliationMappings: state.reconciliationMappings, pendingDoses: allPending
                )
                remaining = r.remainingEvents
                state.lastReconciliation = fetchedAt

                let expirationCutoff = fetchedAt.addingTimeInterval(.hours(-12))
                state.reconciliationMappings = r.reconciliationMappings.filter { $0.value.startTime >= expirationCutoff }

                // Разложить обратно: незавершённые → в слоты unfinalizedBolus/Temp; завершённые
                // остаются в pendingDoses до чистки; фантомный болюс (>1 мин после конца, не в
                // истории) — удалить (зеркало Minimed ~693).
                state.unfinalizedBolus = nil
                state.unfinalizedTempBasal = nil
                state.pendingDoses = r.pendingDoses.filter { dose in
                    if !dose.isFinished {
                        switch dose.doseType {
                        case .bolus: state.unfinalizedBolus = dose
                            return false
                        case .tempBasal: state.unfinalizedTempBasal = dose
                            return false
                        default: break
                        }
                    }
                    if dose.doseType == .bolus, dose.finishTime < fetchedAt.addingTimeInterval(.minutes(-1)),
                       !dose.isReconciledWithHistory
                    {
                        os_log(
                            "Removing bolus that did not reconcile with history: %{public}@",
                            log: self.log,
                            type: .error,
                            String(describing: dose)
                        )
                        return false
                    }
                    return dose.startTime >= expirationCutoff
                }

                // Отмена темпа из истории (аудит B3, зеркало Minimed 702-719): если помпа
                // сама оборвала текущий темп-базал (маркер отмены — событие темпа с
                // startDate==endDate внутри окна нашего темпа), укорачиваем незавершённый
                // темп по этому событию. Иначе state держит фантомный темп на всю
                // длительность → oref завышает базальный IOB.
                if var runningTemp = state.unfinalizedTempBasal {
                    if let cancel = remaining.first(where: { event in
                        guard let dose = event.dose, dose.type == .tempBasal,
                              dose.startDate > runningTemp.startTime,
                              dose.startDate < runningTemp.finishTime,
                              dose.startDate.timeIntervalSince(dose.endDate) == 0
                        else { return false }
                        return true
                    }) {
                        runningTemp.cancel(at: cancel.date, pumpModel: state.pumpModel)
                        state.unfinalizedTempBasal = runningTemp
                        state.suspendState = .resumed(cancel.date)
                    }
                }
            }
            return remaining
        }

        /// Зеркало MinimedPumpManager.updateLastEventDates (строки 810-841).
        /// Обновляет lastRewindDate (смена резервуара) и lastSetChangeDate (смена набора),
        /// сохраняя только самую свежую дату.
        private func updateLastEventDates(from events: [NewPumpEvent]) {
            var latestSetChange: Date?
            var latestRewind: Date?

            for event in events {
                switch event.type {
                case .replaceComponent(componentType: .infusionSet):
                    if latestSetChange == nil || event.date > latestSetChange! {
                        latestSetChange = event.date
                    }
                case .rewind:
                    if latestRewind == nil || event.date > latestRewind! {
                        latestRewind = event.date
                    }
                default:
                    break
                }
            }

            // Обновляем state только если нашли более свежие события.
            mutateState { state in
                if let setChange = latestSetChange {
                    if state.lastSetChangeDate == nil || setChange > state.lastSetChangeDate! {
                        state.lastSetChangeDate = setChange
                    }
                }
                if let rewind = latestRewind {
                    if state.lastRewindDate == nil || rewind > state.lastRewindDate! {
                        state.lastRewindDate = rewind
                    }
                }
            }
        }

        /// Однократный бэкафилл дат смены резервуара и набора.
        /// Читает до 16 страниц истории без фильтра по дате — ищет самые свежие
        /// rewind/setChange которые могли быть старше startDate и не попали в обычный синк.
        /// Вызывается в отдельном Task из syncHistory — не блокирует поллинг.
        private func backfillEventDates() async {
            // Single-flight (аудит B7): syncHistory может стартовать несколько проходов
            // подряд; параллельные 16-страничные бэкафиллы забивают радио и морят голодом
            // команды дозирования. Пускаем строго один за раз.
            guard beginBackfill() else { return }
            defer { endBackfill() }
            guard let c = try? requireClient() else { return }
            let sync = PickleLinkHistorySync(client: c, pumpModel: state.pumpModel, timeZone: state.timeZone)
            do {
                let (rewindDate, setChangeDate) = try await sync.findLastRewindAndSetChange(maxPages: 16)
                mutateState { s in
                    if let d = rewindDate, s.lastRewindDate == nil || d > s.lastRewindDate! {
                        s.lastRewindDate = d
                    }
                    if let d = setChangeDate, s.lastSetChangeDate == nil || d > s.lastSetChangeDate! {
                        s.lastSetChangeDate = d
                    }
                    s.backfillDone = true
                }
                os_log(
                    "Backfill done: rewind=%{public}@, setChange=%{public}@",
                    log: log, type: .info,
                    rewindDate.map { String(describing: $0) } ?? "nil",
                    setChangeDate.map { String(describing: $0) } ?? "nil"
                )
            } catch {
                // Не удалось — попробуем на следующем цикле (backfillDone остаётся false).
                os_log("Backfill failed: %{public}@", log: log, type: .error, String(describing: error))
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
                // Новый SSTAT 0x09 от прошивки 1.4.5: аргументы ушли в эфир, ACK потерян —
                // доза МОГЛА пройти. uncertainDelivery заставит Loop не ретраить (защита
                // от двойной дозы); сама доза уже зафиксирована в enactBolus.
                case .uncertain: return .uncertainDelivery
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
            // Пошёл коннект — ждём готовности GATT; если не поднимется за 12с, watchdog
            // форсирует реконнект (защита от зависшего полу-коннекта).
            scheduleReadyWatchdog(id)
        }

        public func bleManager(_: PickleLinkBLEManager, didDisconnect id: UUID, error _: Error?) {
            cancelReadyWatchdog(id) // коннект оборвался — watchdog больше не нужен
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
            cancelReadyWatchdog(id) // GATT поднялся — снимаем watchdog
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
            case .heartbeat:
                maybeFireBLEHeartbeat()
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
