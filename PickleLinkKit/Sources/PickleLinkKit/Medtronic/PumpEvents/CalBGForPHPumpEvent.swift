import Foundation

public struct CalBGForPHPumpEvent: TimestampedPumpEvent {
    public let length: Int
    public let rawData: Data
    public let timestamp: DateComponents
    public let amount: Int

    public init?(availableData: Data, pumpModel _: PumpModel) {
        length = 7

        guard length <= availableData.count else {
            return nil
        }

        rawData = availableData.subdata(in: 0 ..< length)

        func d(_ idx: Int) -> Int {
            Int(availableData[idx])
        }

        timestamp = DateComponents(pumpEventData: availableData, offset: 2)
        amount = ((d(4) & 0b1000_0000) << 2) + ((d(6) & 0b1000_0000) << 1) + d(1)
    }

    public var dictionaryRepresentation: [String: Any] {
        [
            "_type": "CalBGForPH",
            "amount": amount
        ]
    }
}
