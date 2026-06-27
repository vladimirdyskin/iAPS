import Foundation

public struct ClearAlarmPumpEvent: TimestampedPumpEvent {
    public let length: Int
    public let rawData: Data
    public let timestamp: DateComponents
    public let alarmType: PumpAlarmType

    public init?(availableData: Data, pumpModel _: PumpModel) {
        length = 7

        guard length <= availableData.count else {
            return nil
        }

        rawData = availableData.subdata(in: 0 ..< length)

        alarmType = PumpAlarmType(rawType: availableData[1])

        timestamp = DateComponents(pumpEventData: availableData, offset: 2)
    }

    public var dictionaryRepresentation: [String: Any] {
        [
            "_type": "ClearAlarm",
            "alarm": "\(alarmType)"
        ]
    }
}
