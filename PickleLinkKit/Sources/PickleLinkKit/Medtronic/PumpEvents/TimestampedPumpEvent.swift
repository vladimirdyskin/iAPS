import Foundation

public protocol TimestampedPumpEvent: PumpEvent {
    var timestamp: DateComponents {
        get
    }
}
