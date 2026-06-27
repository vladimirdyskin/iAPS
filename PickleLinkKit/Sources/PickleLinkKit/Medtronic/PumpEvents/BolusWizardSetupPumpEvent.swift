import Foundation

public struct BolusWizardSetupPumpEvent: TimestampedPumpEvent {
    public let length: Int
    public let rawData: Data
    public let timestamp: DateComponents

    public init?(availableData: Data, pumpModel: PumpModel) {
        if pumpModel.larger {
            length = 144
        } else {
            length = 124
        }

        guard length <= availableData.count else {
            return nil
        }

        rawData = availableData.subdata(in: 0 ..< length)

        timestamp = DateComponents(pumpEventData: availableData, offset: 2)
    }

    public var dictionaryRepresentation: [String: Any] {
        [
            "_type": "BolusWizardSetup"
        ]
    }
}
