import Foundation

public struct DailyTotal522PumpEvent: PumpEvent {
    public let length: Int
    public let rawData: Data
    public let timestamp: DateComponents

    public init?(availableData: Data, pumpModel _: PumpModel) {
        length = 44

        guard length <= availableData.count else {
            return nil
        }

        rawData = availableData.subdata(in: 0 ..< length)

        timestamp = DateComponents(pumpEventBytes: availableData.subdata(in: 1 ..< 3))
    }

    public var dictionaryRepresentation: [String: Any] {
        [
            "_type": "DailyTotal522"
        ]
    }
}
