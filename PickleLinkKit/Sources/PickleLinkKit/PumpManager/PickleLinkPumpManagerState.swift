#if canImport(LoopKit)
    import Foundation
    import LoopKit
    // MinimedKit не импортируется: PumpModel, SuspendState, UnfinalizedDose — in-module (Medtronic/)

    /// Связь «событие истории ↔ pending-доза» (зеркало MinimedKit ReconciledDoseMapping).
    /// Когда pending-доза схлопывается с событием истории, её eventRaw попадает сюда и
    /// это событие ИСКЛЮЧАЕТСЯ из отчёта в Loop, пока действует mapping (12ч) — доза
    /// репортится ТОЛЬКО под своим стабильным uuid.raw. Без этого при переходе
    /// pending→removed то же событие всплыло бы под event.raw → дубль дозы в IOB.
    public struct ReconciledDoseMapping: Equatable {
        let startTime: Date
        let uuid: UUID
        let eventRaw: Data
    }

    extension ReconciledDoseMapping: RawRepresentable {
        public typealias RawValue = [String: Any]

        public init?(rawValue: [String: Any]) {
            guard
                let startTime = rawValue["startTime"] as? Date,
                let uuidString = rawValue["uuid"] as? String,
                let uuid = UUID(uuidString: uuidString),
                let eventRawString = rawValue["eventRaw"] as? String,
                let eventRaw = Data(hexadecimalString: eventRawString)
            else {
                return nil
            }
            self.startTime = startTime
            self.uuid = uuid
            self.eventRaw = eventRaw
        }

        public var rawValue: [String: Any] {
            [
                "startTime": startTime,
                "uuid": uuid.uuidString,
                "eventRaw": eventRaw.hexadecimalString
            ]
        }
    }

    public struct PickleLinkPumpManagerState: RawRepresentable, Equatable {
        public typealias RawValue = [String: Any]

        public static let version = 1

        public var isOnboarded: Bool

        /// 6 ASCII digits printed on the back of the pump.
        public var pumpID: String

        /// CoreBluetooth peripheral identifier (for reconnect).
        public var peripheralIdentifier: UUID?

        /// Medtronic pump model resolved during setup (GET_MODEL).
        public var pumpModel: PumpModel

        /// User-pinned radio frequency, Hz. nil → firmware-side mmtune.
        public var frequencyHz: UInt32?

        /// Highest history page index already imported (advances during sync).
        public var lastSyncedHistoryPage: UInt8

        public var timeZone: TimeZone

        public var suspendState: SuspendState

        public var unfinalizedBolus: UnfinalizedDose?
        public var unfinalizedTempBasal: UnfinalizedDose?

        /// Архив завершённых доз, ещё не согласованных с историей помпы. Новый болюс
        /// не должен затирать предыдущий до сверки — старый перекладывается сюда.
        /// Зеркало MinimedKit pendingDoses.
        public var pendingDoses: [UnfinalizedDose] = []

        /// Активные mappings «событие истории → согласованная доза» (12ч TTL).
        /// Держатся между циклами и переживают рестарт — иначе дубль дозы (см.
        /// ReconciledDoseMapping). Зеркало MinimedKit recentlyReconciledEvents.
        public var reconciliationMappings: [Data: ReconciledDoseMapping] = [:]

        /// Время последнего согласования истории с pending-дозами.
        public var lastReconciliation: Date?

        /// Last reservoir reading, in Units.
        public var reservoirUnits: Double?

        public var insulinType: InsulinType?

        /// Заряд батареи помпы (0.0–1.0), обновляется при getBattery (0x04).
        public var pumpBatteryChargeRemaining: Double?

        /// Плановое расписание базала, сохранённое при последнем syncBasalRateSchedule.
        /// Используется для отображения текущей плановой скорости в UI.
        public var basalSchedule: BasalRateSchedule?

        /// Last time the firmware reported a radio error / watchdog (diagnostics only).
        public var lastRadioErrorAt: Date?
        public var lastWatchdogAt: Date?

        /// Дата последнего события перемотки (смена резервуара). Зеркало MinimedPumpManagerState.lastRewindDate.
        public var lastRewindDate: Date?

        /// Дата последней смены набора (fixed prime = смена инфузионного сета). Зеркало MinimedPumpManagerState.lastSetChangeDate.
        public var lastSetChangeDate: Date?

        /// Однократный бэкафилл истории выполнен — не повторять поиск rewind/setChange
        /// без фильтра по дате (дорого по RF). Сбрасывается в false при необходимости
        /// принудительного повтора (например при смене помпы).
        public var backfillDone: Bool

        public init(
            isOnboarded: Bool,
            pumpID: String,
            peripheralIdentifier: UUID?,
            pumpModel: PumpModel,
            frequencyHz: UInt32?,
            timeZone: TimeZone,
            suspendState: SuspendState,
            insulinType: InsulinType?
        )
        {
            self.isOnboarded = isOnboarded
            self.pumpID = pumpID
            self.peripheralIdentifier = peripheralIdentifier
            self.pumpModel = pumpModel
            self.frequencyHz = frequencyHz
            lastSyncedHistoryPage = 0
            self.timeZone = timeZone
            self.suspendState = suspendState
            self.insulinType = insulinType
            backfillDone = false
        }

        // MARK: - RawRepresentable

        public init?(rawValue: RawValue) {
            guard
                let pumpID = rawValue["pumpID"] as? String,
                let pumpModelNumber = rawValue["pumpModel"] as? PumpModel.RawValue,
                let pumpModel = PumpModel(rawValue: pumpModelNumber),
                let timeZoneSeconds = rawValue["timeZone"] as? Int,
                let timeZone = TimeZone(secondsFromGMT: timeZoneSeconds)
            else {
                return nil
            }

            self.pumpID = pumpID
            self.pumpModel = pumpModel
            self.timeZone = timeZone
            isOnboarded = rawValue["isOnboarded"] as? Bool ?? true
            lastSyncedHistoryPage = UInt8(rawValue["lastSyncedHistoryPage"] as? Int ?? 0)
            reservoirUnits = rawValue["reservoirUnits"] as? Double

            if let s = rawValue["peripheralIdentifier"] as? String {
                peripheralIdentifier = UUID(uuidString: s)
            }
            if let f = rawValue["frequencyHz"] as? Int {
                frequencyHz = UInt32(f)
            }

            if let rawSuspendState = rawValue["suspendState"] as? SuspendState.RawValue,
               let s = SuspendState(rawValue: rawSuspendState)
            {
                suspendState = s
            } else {
                suspendState = .resumed(Date())
            }

            if let raw = rawValue["unfinalizedBolus"] as? UnfinalizedDose.RawValue {
                unfinalizedBolus = UnfinalizedDose(rawValue: raw)
            }
            if let raw = rawValue["unfinalizedTempBasal"] as? UnfinalizedDose.RawValue {
                unfinalizedTempBasal = UnfinalizedDose(rawValue: raw)
            }
            if let rawPending = rawValue["pendingDoses"] as? [UnfinalizedDose.RawValue] {
                pendingDoses = rawPending.compactMap { UnfinalizedDose(rawValue: $0) }
            }
            if let rawMappings = rawValue["reconciliationMappings"] as? [ReconciledDoseMapping.RawValue] {
                let mappings = rawMappings.compactMap { ReconciledDoseMapping(rawValue: $0) }
                reconciliationMappings = Dictionary(mappings.map { ($0.eventRaw, $0) }, uniquingKeysWith: { _, new in new })
            }
            lastReconciliation = rawValue["lastReconciliation"] as? Date
            if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue {
                insulinType = InsulinType(rawValue: rawInsulinType)
            }
            pumpBatteryChargeRemaining = rawValue["pumpBatteryChargeRemaining"] as? Double
            lastRadioErrorAt = rawValue["lastRadioErrorAt"] as? Date
            lastWatchdogAt = rawValue["lastWatchdogAt"] as? Date
            lastRewindDate = rawValue["lastRewindDate"] as? Date
            lastSetChangeDate = rawValue["lastSetChangeDate"] as? Date
            backfillDone = rawValue["backfillDone"] as? Bool ?? false
            if let rawSchedule = rawValue["basalSchedule"] as? BasalRateSchedule.RawValue {
                basalSchedule = BasalRateSchedule(rawValue: rawSchedule)
            }
        }

        public var rawValue: RawValue {
            var value: RawValue = [
                "version": PickleLinkPumpManagerState.version,
                "isOnboarded": isOnboarded,
                "pumpID": pumpID,
                "pumpModel": pumpModel.rawValue,
                "lastSyncedHistoryPage": Int(lastSyncedHistoryPage),
                "timeZone": timeZone.secondsFromGMT(),
                "suspendState": suspendState.rawValue
            ]
            value["peripheralIdentifier"] = peripheralIdentifier?.uuidString
            value["frequencyHz"] = frequencyHz.map { Int($0) }
            value["reservoirUnits"] = reservoirUnits
            value["pumpBatteryChargeRemaining"] = pumpBatteryChargeRemaining
            value["unfinalizedBolus"] = unfinalizedBolus?.rawValue
            value["unfinalizedTempBasal"] = unfinalizedTempBasal?.rawValue
            value["pendingDoses"] = pendingDoses.map(\.rawValue)
            value["reconciliationMappings"] = reconciliationMappings.values.map(\.rawValue)
            value["lastReconciliation"] = lastReconciliation
            value["insulinType"] = insulinType?.rawValue
            value["lastRadioErrorAt"] = lastRadioErrorAt
            value["lastWatchdogAt"] = lastWatchdogAt
            value["lastRewindDate"] = lastRewindDate
            value["lastSetChangeDate"] = lastSetChangeDate
            value["backfillDone"] = backfillDone
            value["basalSchedule"] = basalSchedule?.rawValue
            return value
        }
    }

    extension PickleLinkPumpManagerState: CustomDebugStringConvertible {
        public var debugDescription: String {
            [
                "## PickleLinkPumpManagerState",
                "isOnboarded: \(isOnboarded)",
                "pumpID: ✔︎",
                "pumpModel: \(pumpModel.rawValue)",
                "peripheralIdentifier: \(String(describing: peripheralIdentifier))",
                "frequencyHz: \(String(describing: frequencyHz))",
                "lastSyncedHistoryPage: \(lastSyncedHistoryPage)",
                "suspendState: \(suspendState)",
                "reservoirUnits: \(String(describing: reservoirUnits))",
                "unfinalizedBolus: \(String(describing: unfinalizedBolus))",
                "unfinalizedTempBasal: \(String(describing: unfinalizedTempBasal))",
                "insulinType: \(String(describing: insulinType))",
                "lastRadioErrorAt: \(String(describing: lastRadioErrorAt))",
                "lastWatchdogAt: \(String(describing: lastWatchdogAt))"
            ].joined(separator: "\n")
        }
    }
#endif
