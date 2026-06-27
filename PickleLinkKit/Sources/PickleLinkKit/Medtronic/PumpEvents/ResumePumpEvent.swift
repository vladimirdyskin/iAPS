import Foundation

public struct ResumePumpEvent: TimestampedPumpEvent {
    public let length: Int
    public let rawData: Data
    public let timestamp: DateComponents
    public let wasRemotelyTriggered: Bool

    public init?(availableData: Data, pumpModel _: PumpModel) {
        length = 7

        guard length <= availableData.count else {
            return nil
        }

        rawData = availableData.subdata(in: 0 ..< length)

        timestamp = DateComponents(pumpEventData: availableData, offset: 2)

        wasRemotelyTriggered = availableData[5] & 0b0100_0000 != 0
    }

    public var dictionaryRepresentation: [String: Any] {
        [
            "_type": "Resume",
            "wasRemotelyTriggered": wasRemotelyTriggered
        ]
    }
}
