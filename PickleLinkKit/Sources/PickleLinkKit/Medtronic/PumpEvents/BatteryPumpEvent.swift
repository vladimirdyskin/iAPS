import Foundation

public struct BatteryPumpEvent: TimestampedPumpEvent {
    public let length: Int
    public let rawData: Data
    public let isPresent: Bool
    public let timestamp: DateComponents

    public init?(availableData: Data, pumpModel _: PumpModel) {
        length = 7

        guard length <= availableData.count else {
            return nil
        }

        rawData = availableData.subdata(in: 0 ..< length)

        isPresent = availableData[1] != 0

        timestamp = DateComponents(pumpEventData: availableData, offset: 2)
    }

    public var dictionaryRepresentation: [String: Any] {
        [
            "_type": "Battery",
            "isPresent": isPresent
        ]
    }
}
