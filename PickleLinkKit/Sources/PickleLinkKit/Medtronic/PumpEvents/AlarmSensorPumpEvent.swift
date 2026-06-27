import Foundation

public struct AlarmSensorPumpEvent: TimestampedPumpEvent {
    public let length: Int
    public let rawData: Data
    public let timestamp: DateComponents

    public init?(availableData: Data, pumpModel _: PumpModel) {
        length = 8

        guard length <= availableData.count else {
            return nil
        }

        rawData = availableData.subdata(in: 0 ..< length)

        timestamp = DateComponents(pumpEventData: availableData, offset: 3)
    }

    public var dictionaryRepresentation: [String: Any] {
        [
            "_type": "AlarmSensor"
        ]
    }

    public var description: String {
        LocalizedString("AlarmSensor", comment: "The description of AlarmSensorPumpEvent")
    }
}
