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

        private let bleManager: PickleLinkBLEManager
        private var peripheral: PickleLinkPeripheral?
        private var client: PickleLinkClient?

        private let hkDevice: HKDevice

        // MARK: - Delegate plumbing

        private let statusObservers = NSHashTable<AnyObject>.weakObjects()
        private var statusObserverQueues: [ObjectIdentifier: DispatchQueue] = [:]

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
                bleManager.connect(id: id)
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
                pumpBatteryChargeRemaining: nil,
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
        }

        // MARK: - Client access

        private func requireClient() throws -> PickleLinkClient {
            guard let c = client else { throw PumpManagerError.connection(nil) }
            return c
        }

        /// Diagnostic accessor for the settings UI (0x12 GET_STATISTICS).
        public func fetchStatistics() async throws -> DeviceStatistics {
            try await requireClient().getStatistics()
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
                    let start = Date()
                    try await c.bolus(amountMilliunits: mu)

                    // Post-bolus confirmation (protocol §0x0D): the firmware does this,
                    // but verify on the plugin side too.
                    let status = try? await c.getStatus()
                    if let status, !status.bolusing {
                        completion(.deviceState(nil))
                        return
                    }

                    let duration = self.state.pumpModel.bolusDeliveryTime(units: units)
                    let dose = UnfinalizedDose(
                        bolusAmount: units, startTime: start, duration: duration,
                        insulinType: self.state.insulinType,
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
            // Smart Bridge has no bolus-cancel command; report failure so Loop keeps the dose.
            completion(.failure(.deviceState(nil)))
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
                    _ = try? await c.getBattery() // 0x04
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
            items _: [RepeatingScheduleValue<Double>],
            completion: @escaping (Result<BasalRateSchedule, Error>) -> Void
        ) {
            // Read-back only — firmware does not accept a basal profile write (0x0C is read).
            Task {
                do {
                    let entries = try await requireClient().getBasalRates() // 0x0C
                    let items = entries.map {
                        RepeatingScheduleValue<Double>(
                            startTime: TimeInterval($0.startSeconds),
                            value: PickleLinkConversions.milliunitsToUnits($0.rateMu)
                        )
                    }
                    if let schedule = BasalRateSchedule(dailyItems: items, timeZone: self.state.timeZone) {
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
            // 0x0B is read-only; echo requested limits back (no write path on firmware).
            Task {
                _ = try? await requireClient().getSettings() // 0x0B (diagnostic read)
                completion(.success(deliveryLimits))
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
                var date = Date().addingTimeInterval(-.hours(24))
                q.sync { date = d.startDateToFilterNewPumpEvents(for: self) }
                return date
            }
            return Date().addingTimeInterval(-.hours(24))
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

        public func bleManager(_: PickleLinkBLEManager, didUpdateDiscovered _: [DiscoveredDevice]) {}

        public func bleManager(_: PickleLinkBLEManager, didConnect peripheral: PickleLinkPeripheral) {
            self.peripheral = peripheral
            peripheral.delegate = self
            // One BLEManager → one peripheral → one client.
            let c = PickleLinkClient(transport: peripheral)
            client = c
        }

        public func bleManager(_: PickleLinkBLEManager, didDisconnect _: UUID, error _: Error?) {
            let c = client
            Task { await c?.disconnect() }
            client = nil
            peripheral = nil
        }

        public func peripheralIsReady(_: PickleLinkPeripheral) {}

        /// The glue the BLE-layer agent intentionally left open:
        /// PickleLinkPeripheral.didReceiveResponse → PickleLinkClient.ingestResponse.
        public func peripheral(_: PickleLinkPeripheral, didReceiveResponse data: Data) {
            let c = client
            Task { await c?.ingestResponse(data) }
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
    }
#endif
