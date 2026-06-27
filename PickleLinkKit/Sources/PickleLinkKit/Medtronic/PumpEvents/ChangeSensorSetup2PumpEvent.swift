import Foundation

public struct ChangeSensorSetup2PumpEvent: TimestampedPumpEvent {
    public let length: Int
    public let rawData: Data
    public let timestamp: DateComponents

    public init?(availableData: Data, pumpModel: PumpModel) {
        if pumpModel.hasLowSuspend {
            length = 41
        } else {
            length = 37
        }

        guard length <= availableData.count else {
            return nil
        }

        rawData = availableData.subdata(in: 0 ..< length)

        timestamp = DateComponents(pumpEventData: availableData, offset: 2)
    }

    public var dictionaryRepresentation: [String: Any] {
        [
            "_type": "ChangeSensorSetup2"
        ]
    }
}
