@testable import PickleLinkKit
import XCTest

final class SmartBridgeCommandTests: XCTestCase {
    // MARK: - Encode

    func testCommandFrameEncodeNoParams() {
        let f = CommandFrame(seq: 0x42, command: .ping)
        XCTAssertEqual(f.encode(), Data([0x42, 0x13]))
    }

    func testGetModelEncode() {
        let f = CommandFrame(seq: 0x01, command: .getModel)
        XCTAssertEqual(f.encode(), Data([0x01, 0x03]))
    }

    func testGetBatteryEncode() {
        let f = CommandFrame(seq: 0xFF, command: .getBattery)
        XCTAssertEqual(f.encode(), Data([0xFF, 0x04]))
    }

    func testGetHistoryInfoEncode() {
        let f = CommandFrame(seq: 0x10, command: .getHistoryInfo)
        XCTAssertEqual(f.encode(), Data([0x10, 0x14]))
    }

    func testSetTempBasalParams() {
        // rate=1500 mU/h (1.5 U/h), duration=30 min
        let p = SCMDParams.setTempBasal(rateMilliunitsPerHour: 1500, durationMinutes: 30)
        // 1500 = 0x000005DC, 30 = 0x001E
        XCTAssertEqual(p, Data([0x00, 0x00, 0x05, 0xDC, 0x00, 0x1E]))

        let f = CommandFrame(seq: 0x07, command: .setTempBasal, params: p)
        XCTAssertEqual(f.encode(), Data([0x07, 0x09, 0x00, 0x00, 0x05, 0xDC, 0x00, 0x1E]))
    }

    func testBolusParams() {
        // 2.0 U = 2000 mU = 0x000007D0
        let p = SCMDParams.bolus(amountMilliunits: 2000)
        XCTAssertEqual(p, Data([0x00, 0x00, 0x07, 0xD0]))
    }

    func testSetFrequencyLE() {
        // 868_500_000 Hz = 0x33C44220 → LE bytes 0x20 0x42 0xC4 0x33
        let p = SCMDParams.setFrequency(hz: 868_500_000)
        XCTAssertEqual(p, Data([0x20, 0x42, 0xC4, 0x33]))
    }

    func testConfigurePumpParams() {
        let p = SCMDParams.configurePump(pumpID: "123456")
        XCTAssertEqual(p, Data("123456".utf8))
        XCTAssertEqual(p.count, 6)
    }

    // MARK: - Decode (response payloads)

    func testDecodeModel() throws {
        // Spec example: 0x0207 = 522
        let payload = Data([0x02, 0x07])
        XCTAssertEqual(try SmartBridgeDecode.model(payload), 0x0207)
    }

    func testDecodeBattery() throws {
        // Spec example: 0x0594 = 1428 mV
        let payload = Data([0x05, 0x94])
        let b = try SmartBridgeDecode.battery(payload)
        XCTAssertEqual(b.millivolts, 1428)
    }

    func testDecodeReservoir() throws {
        // 175.5 U = 175500 mU = 0x0002AD8C
        let payload = Data([0x00, 0x02, 0xAD, 0x8C])
        let r = try SmartBridgeDecode.reservoir(payload)
        XCTAssertEqual(r.milliunits, 175_500)
        XCTAssertEqual(r.units, 175.5, accuracy: 1E-6)
    }

    func testDecodeStatus() throws {
        let s = try SmartBridgeDecode.status(Data([0x03, 0x01, 0x00]))
        XCTAssertEqual(s.code, 0x03)
        XCTAssertTrue(s.bolusing)
        XCTAssertFalse(s.suspended)
    }

    func testDecodeTempBasal() throws {
        // 1500 mU/h, 30 min remaining
        let p = Data([0x00, 0x00, 0x05, 0xDC, 0x00, 0x1E])
        let tb = try SmartBridgeDecode.tempBasal(p)
        XCTAssertEqual(tb.rateMilliunitsPerHour, 1500)
        XCTAssertEqual(tb.minutesRemaining, 30)
    }

    func testDecodeSettings() throws {
        // dia=5, tempBasalType=0, maxBasal=2000 mU, maxBolus=10_000 mU
        // 2000 = 0x000007D0, 10000 = 0x00002710
        let p = Data([0x05, 0x00, 0x00, 0x00, 0x07, 0xD0, 0x00, 0x00, 0x27, 0x10])
        let s = try SmartBridgeDecode.settings(p)
        XCTAssertEqual(s.dia, 5)
        XCTAssertEqual(s.tempBasalType, 0)
        XCTAssertEqual(s.maxBasalMu, 2000)
        XCTAssertEqual(s.maxBolusMu, 10000)
    }

    func testDecodeBasalRates() throws {
        // 2 entries: midnight @ 1.0 U/h (1000 mU), 06:00 (21600s) @ 1.5 U/h (1500 mU)
        let p = Data([
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8, // 0 sec, 1000 mU
            0x00, 0x00, 0x54, 0x60, 0x00, 0x00, 0x05, 0xDC // 21600 sec, 1500 mU
        ])
        let entries = try SmartBridgeDecode.basalRates(p)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].startSeconds, 0)
        XCTAssertEqual(entries[0].rateMu, 1000)
        XCTAssertEqual(entries[1].startSeconds, 21600)
        XCTAssertEqual(entries[1].rateMu, 1500)
    }

    func testDecodeBasalRatesMalformed() {
        XCTAssertThrowsError(try SmartBridgeDecode.basalRates(Data([0x00, 0x00, 0x00])))
    }

    func testDecodeHistoryInfo() throws {
        // current_page=12, max_page=35, offset=0x0204 = 516
        let p = Data([0x0C, 0x23, 0x02, 0x04])
        let h = try SmartBridgeDecode.historyInfo(p)
        XCTAssertEqual(h.currentPage, 12)
        XCTAssertEqual(h.maxPage, 35)
        XCTAssertEqual(h.pageOffset, 516)
    }

    func testDecodeStatistics() throws {
        // batt 3100 mV (0x0C1C), 75%, rx=300 (0x012C), tx=5
        let p = Data([0x0C, 0x1C, 0x4B, 0x01, 0x2C, 0x05])
        let s = try SmartBridgeDecode.statistics(p)
        XCTAssertEqual(s.batteryMv, 3100)
        XCTAssertEqual(s.batteryPct, 75)
        XCTAssertEqual(s.rxCount, 300)
        XCTAssertEqual(s.txCount, 5)
    }

    func testDecodePing() throws {
        let p = Data("pickle_smart 1.0".utf8)
        XCTAssertEqual(try SmartBridgeDecode.ping(p), "pickle_smart 1.0")
    }

    func testShortPayloadThrows() {
        XCTAssertThrowsError(try SmartBridgeDecode.model(Data([0x01])))
        XCTAssertThrowsError(try SmartBridgeDecode.battery(Data()))
        XCTAssertThrowsError(try SmartBridgeDecode.reservoir(Data([0x01, 0x02, 0x03])))
        XCTAssertThrowsError(try SmartBridgeDecode.historyInfo(Data([0x01, 0x02, 0x03])))
    }

    func testAllCommandsHaveDistinctRawValues() {
        let raws = SCMD.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, 20)
        XCTAssertEqual(Set(raws).count, 20)
    }
}
