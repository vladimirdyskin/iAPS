@testable import PickleLinkKit
import XCTest

final class StatusEventTests: XCTestCase {
    func testReady() {
        let e = StatusEvent(raw: Data([0x01]))
        XCTAssertEqual(e, .ready)
    }

    func testBatteryLow() {
        // 3.2V = 3200 mV = 0x0C80
        let e = StatusEvent(raw: Data([0x02, 0x0C, 0x80]))
        XCTAssertEqual(e, .batteryLow(deviceMv: 3200))
    }

    func testRadioError() {
        // 3 consecutive errors, last rssi raw 180 → -90 dBm
        let e = StatusEvent(raw: Data([0x03, 0x03, 0xB4]))
        XCTAssertEqual(e, .radioError(consecutiveErrors: 3, lastRssiRaw: 0xB4))
        if case let .radioError(_, raw) = e {
            XCTAssertEqual(StatusEvent.rssiDbm(fromRaw: raw), -90)
        } else {
            XCTFail("wrong case")
        }
    }

    func testPumpReachable() {
        let e = StatusEvent(raw: Data([0x04, 0xA0]))
        XCTAssertEqual(e, .pumpReachable(lastRssiRaw: 0xA0))
    }

    func testWatchdogPending() {
        let e = StatusEvent(raw: Data([0x05]))
        XCTAssertEqual(e, .watchdogPending)
    }

    func testFrequencyChangedLE() {
        // 868_500_000 Hz = 0x33C44220 LE: 0x20 0x42 0xC4 0x33
        let e = StatusEvent(raw: Data([0x06, 0x20, 0x42, 0xC4, 0x33]))
        XCTAssertEqual(e, .frequencyChanged(hz: 868_500_000))
    }

    func testUnknownEventRetained() {
        let raw = Data([0xFE, 0xAA, 0xBB])
        let e = StatusEvent(raw: raw)
        XCTAssertEqual(e, .unknown(eventType: 0xFE, data: Data([0xAA, 0xBB])))
    }

    func testEmptyData() {
        XCTAssertNil(StatusEvent(raw: Data()))
    }

    func testBatteryLowTooShort() {
        XCTAssertNil(StatusEvent(raw: Data([0x02, 0x0C])))
    }
}
