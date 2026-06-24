@testable import PickleLinkKit
import XCTest

final class PickleLinkConversionsTests: XCTestCase {
    func testUnitsToMilliunitsRoundsAndClamps() {
        XCTAssertEqual(PickleLinkConversions.unitsToMilliunits(1.0), 1000)
        XCTAssertEqual(PickleLinkConversions.unitsToMilliunits(0.025), 25)
        XCTAssertEqual(PickleLinkConversions.unitsToMilliunits(0.0014), 1) // rounds 1.4 → 1
        XCTAssertEqual(PickleLinkConversions.unitsToMilliunits(-5), 0) // clamp negative
    }

    func testMilliunitsToUnitsRoundTrip() {
        let mu = PickleLinkConversions.unitsToMilliunits(2.350)
        XCTAssertEqual(mu, 2350)
        XCTAssertEqual(PickleLinkConversions.milliunitsToUnits(mu), 2.350, accuracy: 1E-9)
    }

    func testMinutesFromDuration() {
        XCTAssertEqual(PickleLinkConversions.minutes(from: 30 * 60), 30)
        XCTAssertEqual(PickleLinkConversions.minutes(from: 0), 0)
        XCTAssertEqual(PickleLinkConversions.minutes(from: 89), 1) // 1.48 min → 1
        XCTAssertEqual(PickleLinkConversions.minutes(from: -10), 0)
    }

    func testMedtronicModelMapping() {
        // Прошивка отдаёт номер модели десятичным числом (ASCII-ответ помпы → int).
        XCTAssertEqual(PickleLinkConversions.medtronicModelString(fromRaw: 722), "722") // 0x02D2
        XCTAssertEqual(PickleLinkConversions.medtronicModelString(fromRaw: 522), "522") // 0x020A
        XCTAssertEqual(PickleLinkConversions.medtronicModelString(fromRaw: 523), "523")
    }
}
