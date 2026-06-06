import Foundation

/// Abstract transport: encode-and-send command bytes, receive response/status notify bytes.
/// Allows unit tests to inject a mock instead of CoreBluetooth.
public protocol CommandTransport: AnyObject, Sendable {
    /// Write encoded command frame to Command characteristic.
    /// Returns when the write completes (or has been queued without ack — vendor choice).
    func sendCommand(_ frame: Data) async throws
}
