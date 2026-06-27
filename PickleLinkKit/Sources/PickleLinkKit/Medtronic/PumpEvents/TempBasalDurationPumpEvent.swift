import Foundation

public struct TempBasalDurationPumpEvent: TimestampedPumpEvent {
    public let length: Int
    public let rawData: Data
    public let duration: Int
    public let timestamp: DateComponents

    public init?(availableData: Data, pumpModel _: PumpModel) {
        length = 7

        func d(_ idx: Int) -> Int {
            Int(availableData[idx])
        }

        guard length <= availableData.count else {
            return nil
        }

        rawData = availableData.subdata(in: 0 ..< length)

        duration = d(1) * 30
        timestamp = DateComponents(pumpEventData: availableData, offset: 2)
    }

    public var dictionaryRepresentation: [String: Any] {
        [
            "_type": "TempBasalDuration",
            "duration": duration
        ]
    }

    public var description: String {
        String(
            format: LocalizedString(
                "Temporary Basal: %1$d min",
                comment: "The format string description of a TempBasalDurationPumpEvent. (1: The duration of the temp basal in minutes)"
            ),
            duration
        )
    }
}
