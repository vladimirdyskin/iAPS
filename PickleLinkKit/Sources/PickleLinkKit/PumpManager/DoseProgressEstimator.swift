#if canImport(LoopKit)
    import Foundation
    import LoopKit
    import MinimedKit

    final class PickleLinkDoseProgressEstimator: DoseProgressTimerEstimator {
        let dose: DoseEntry
        let pumpModel: PumpModel

        init(dose: DoseEntry, pumpModel: PumpModel, reportingQueue: DispatchQueue) {
            self.dose = dose
            self.pumpModel = pumpModel
            super.init(reportingQueue: reportingQueue)
        }

        override var progress: DoseProgress {
            let elapsed = -dose.startDate.timeIntervalSinceNow
            let programmed = dose.programmedUnits ?? dose.value
            let (deliveredUnits, percent) = pumpModel.estimateBolusProgress(
                elapsed: elapsed,
                programmedUnits: programmed
            )
            return DoseProgress(deliveredUnits: deliveredUnits, percentComplete: percent)
        }

        override func timerParameters() -> (delay: TimeInterval, repeating: TimeInterval) {
            let timeSinceStart = -dose.startDate.timeIntervalSinceNow
            let duration = dose.endDate.timeIntervalSince(dose.startDate)
            let programmed = dose.programmedUnits ?? dose.value
            guard programmed > 0, duration > 0 else {
                return (delay: 1, repeating: 1)
            }
            let timeBetweenPulses = duration / (Double(pumpModel.pulsesPerUnit) * programmed)
            let delayUntilNextPulse = timeBetweenPulses - timeSinceStart.remainder(dividingBy: timeBetweenPulses)
            return (delay: delayUntilNextPulse, repeating: timeBetweenPulses)
        }
    }
#endif
