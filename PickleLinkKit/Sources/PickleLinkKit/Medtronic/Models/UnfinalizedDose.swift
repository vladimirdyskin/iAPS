#if canImport(LoopKit)
    import Foundation
    import LoopKit

    public struct UnfinalizedDose: RawRepresentable, Equatable, CustomStringConvertible {
        public typealias RawValue = [String: Any]

        enum DoseType: Int {
            case bolus = 0
            case tempBasal
            case suspend
            case resume
        }

        let doseType: DoseType
        public var units: Double
        var programmedUnits: Double? // Set when finalized; tracks programmed units
        var programmedTempRate: Double? // Set when finalized; tracks programmed temp rate
        let startTime: Date
        var duration: TimeInterval
        var isReconciledWithHistory: Bool
        var uuid: UUID
        let insulinType: InsulinType?
        let automatic: Bool?

        var finishTime: Date {
            get {
                startTime.addingTimeInterval(duration)
            }
            set {
                duration = newValue.timeIntervalSince(startTime)
            }
        }

        public var progress: Double {
            let elapsed = -startTime.timeIntervalSinceNow
            return min(elapsed / duration, 1)
        }

        public var isFinished: Bool {
            progress >= 1
        }

        // Units per hour
        public var rate: Double {
            guard duration.hours > 0 else {
                return 0
            }

            return units / duration.hours
        }

        public var finalizedUnits: Double? {
            guard isFinished else {
                return nil
            }
            return units
        }

        public init(
            bolusAmount: Double,
            startTime: Date,
            duration: TimeInterval,
            insulinType: InsulinType?,
            automatic: Bool,
            isReconciledWithHistory: Bool = false
        ) {
            doseType = .bolus
            units = bolusAmount
            self.startTime = startTime
            self.duration = duration
            programmedUnits = nil
            self.insulinType = insulinType
            uuid = UUID()
            self.isReconciledWithHistory = isReconciledWithHistory
            self.automatic = automatic
        }

        public init(
            tempBasalRate: Double,
            startTime: Date,
            duration: TimeInterval,
            insulinType: InsulinType?,
            automatic: Bool = true,
            isReconciledWithHistory: Bool = false
        ) {
            doseType = .tempBasal
            units = tempBasalRate * duration.hours
            self.startTime = startTime
            self.duration = duration
            programmedUnits = nil
            self.insulinType = insulinType
            self.automatic = automatic
            self.isReconciledWithHistory = isReconciledWithHistory
            uuid = UUID()
        }

        init(suspendStartTime: Date, isReconciledWithHistory: Bool = false) {
            doseType = .suspend
            units = 0
            startTime = suspendStartTime
            duration = 0
            self.isReconciledWithHistory = isReconciledWithHistory
            insulinType = nil
            automatic = false
            uuid = UUID()
        }

        init(resumeStartTime: Date, insulinType: InsulinType, isReconciledWithHistory: Bool = false) {
            doseType = .resume
            units = 0
            startTime = resumeStartTime
            duration = 0
            self.insulinType = insulinType
            self.isReconciledWithHistory = isReconciledWithHistory
            automatic = false
            uuid = UUID()
        }

        public mutating func cancel(at date: Date, pumpModel: PumpModel) {
            guard date < finishTime else {
                return
            }

            let programmedUnits = units
            self.programmedUnits = programmedUnits

            // Guard against negative duration if clock has changed
            let newDuration = max(0, date.timeIntervalSince(startTime))

            switch doseType {
            case .bolus:
                (units, _) = pumpModel.estimateBolusProgress(elapsed: newDuration, programmedUnits: programmedUnits)
            case .tempBasal:
                programmedTempRate = rate
                (units, _) = pumpModel.estimateTempBasalProgress(unitsPerHour: rate, duration: duration, elapsed: newDuration)
            default:
                break
            }
            duration = newDuration
        }

        public var description: String {
            switch doseType {
            case .bolus:
                return "Bolus units:\(programmedUnits ?? units) \(startTime)"
            case .tempBasal:
                return "TempBasal rate:\(programmedTempRate ?? rate) \(startTime) duration:\(String(describing: duration))"
            default:
                return "\(String(describing: doseType).capitalized) \(startTime)"
            }
        }

        public var eventTitle: String {
            switch doseType {
            case .bolus:
                return LocalizedString("Bolus", comment: "Pump Event title for UnfinalizedDose with doseType of .bolus")
            case .resume:
                return LocalizedString("Resume", comment: "Pump Event title for UnfinalizedDose with doseType of .resume")
            case .suspend:
                return LocalizedString("Suspend", comment: "Pump Event title for UnfinalizedDose with doseType of .suspend")
            case .tempBasal:
                return LocalizedString("Temp Basal", comment: "Pump Event title for UnfinalizedDose with doseType of .tempBasal")
            }
        }

        public mutating func reconcile(with event: NewPumpEvent) {
            isReconciledWithHistory = true
            if let dose = event.dose {
                switch dose.type {
                case .bolus:
                    if programmedUnits == nil {
                        programmedUnits = units
                    }
                    let doseDuration = dose.endDate.timeIntervalSince(dose.startDate)

                    if doseDuration > 0, doseDuration < duration {
                        duration = doseDuration
                    }
                    if let deliveredUnits = dose.deliveredUnits {
                        units = deliveredUnits
                    }
                default:
                    break
                }
            }
        }

        // MARK: - RawRepresentable

        public init?(rawValue: RawValue) {
            guard
                let rawDoseType = rawValue["doseType"] as? Int,
                let doseType = DoseType(rawValue: rawDoseType),
                let units = rawValue["units"] as? Double,
                let startTime = rawValue["startTime"] as? Date,
                let duration = rawValue["duration"] as? Double
            else {
                return nil
            }

            self.doseType = doseType
            self.units = units
            self.startTime = startTime
            self.duration = duration

            if let scheduledUnits = rawValue["scheduledUnits"] as? Double {
                programmedUnits = scheduledUnits
            }

            if let scheduledTempRate = rawValue["scheduledTempRate"] as? Double {
                programmedTempRate = scheduledTempRate
            }

            if let uuidString = rawValue["uuid"] as? String {
                if let uuid = UUID(uuidString: uuidString) {
                    self.uuid = uuid
                } else {
                    return nil
                }
            } else {
                uuid = UUID()
            }

            if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue,
               let insulinType = InsulinType(rawValue: rawInsulinType)
            {
                self.insulinType = insulinType
            } else {
                insulinType = nil
            }

            isReconciledWithHistory = rawValue["isReconciledWithHistory"] as? Bool ?? false

            let defaultAutomaticState = doseType == .tempBasal

            automatic = rawValue["automatic"] as? Bool ?? defaultAutomaticState
        }

        public var rawValue: RawValue {
            var rawValue: RawValue = [
                "doseType": doseType.rawValue,
                "units": units,
                "startTime": startTime,
                "duration": duration,
                "isReconciledWithHistory": isReconciledWithHistory,
                "uuid": uuid.uuidString
            ]

            if let scheduledUnits = programmedUnits {
                rawValue["scheduledUnits"] = scheduledUnits
            }

            if let scheduledTempRate = programmedTempRate {
                rawValue["scheduledTempRate"] = scheduledTempRate
            }

            if let insulinType = insulinType {
                rawValue["insulinType"] = insulinType.rawValue
            }

            if let automatic = automatic {
                rawValue["automatic"] = automatic
            }

            return rawValue
        }
    }

    // MARK: - UnfinalizedDose

    extension UnfinalizedDose {
        func newPumpEvent(forceFinalization: Bool = false) -> NewPumpEvent {
            NewPumpEvent(self, forceFinalization: forceFinalization)
        }
    }

    // MARK: - NewPumpEvent

    extension NewPumpEvent {
        init(_ dose: UnfinalizedDose, forceFinalization: Bool = false) {
            let entry = DoseEntry(dose, forceFinalization: forceFinalization)
            let raw = dose.uuid.asRaw
            self.init(date: dose.startTime, dose: entry, raw: raw, title: dose.eventTitle)
        }
    }

    // MARK: - DoseEntry

    public extension DoseEntry {
        init(_ dose: UnfinalizedDose, forceFinalization: Bool = false) {
            switch dose.doseType {
            case .bolus:
                self = DoseEntry(
                    type: .bolus,
                    startDate: dose.startTime,
                    endDate: dose.finishTime,
                    value: dose.programmedUnits ?? dose.units,
                    unit: .units,
                    deliveredUnits: dose.finalizedUnits,
                    insulinType: dose.insulinType,
                    automatic: dose.automatic,
                    isMutable: !dose.isReconciledWithHistory && !forceFinalization
                )
            case .tempBasal:
                let isMutable = !forceFinalization && (!dose.isReconciledWithHistory || !dose.isFinished)
                self = DoseEntry(
                    type: .tempBasal,
                    startDate: dose.startTime,
                    endDate: dose.finishTime,
                    value: dose.programmedTempRate ?? dose.rate,
                    unit: .unitsPerHour,
                    deliveredUnits: dose.finalizedUnits,
                    insulinType: dose.insulinType,
                    automatic: dose.automatic,
                    isMutable: isMutable
                )
            case .suspend:
                self = DoseEntry(suspendDate: dose.startTime, isMutable: !dose.isReconciledWithHistory)
            case .resume:
                self = DoseEntry(
                    resumeDate: dose.startTime,
                    insulinType: dose.insulinType,
                    isMutable: !dose.isReconciledWithHistory
                )
            }
        }
    }

    extension Collection where Element == NewPumpEvent {
        /// find matching entry
        func firstMatchingIndex(for dose: UnfinalizedDose, within: TimeInterval) -> Self.Index? {
            firstIndex(where: { (event) -> Bool in
                guard let type = event.type, let eventDose = event.dose,
                      abs(eventDose.startDate.timeIntervalSince(dose.startTime)) < within
                else {
                    return false
                }

                switch dose.doseType {
                case .bolus:
                    return type == .bolus && eventDose.programmedUnits == dose.programmedUnits ?? dose.units
                case .tempBasal:
                    return type == .tempBasal && eventDose.unitsPerHour == dose.programmedTempRate ?? dose.rate
                case .suspend:
                    return type == .suspend
                case .resume:
                    return type == .resume
                }
            })
        }
    }

    extension UUID {
        var asRaw: Data {
            withUnsafePointer(to: self) {
                Data(bytes: $0, count: MemoryLayout.size(ofValue: self))
            }
        }
    }
#endif
