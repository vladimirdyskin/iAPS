@testable import PickleLinkKit
import XCTest

/// Mock transport that records frames sent and lets the test drive responses.
final class MockTransport: CommandTransport, @unchecked Sendable {
    var sent: [Data] = []
    var onSend: ((Data) -> Void)?

    func sendCommand(_ frame: Data) async throws {
        sent.append(frame)
        onSend?(frame)
    }
}

final class FragmentReassemblyTests: XCTestCase {
    func testFragmentInfoEncoding() {
        let f0 = FragmentInfo(byte: 0x80)
        XCTAssertEqual(f0.index, 0)
        XCTAssertTrue(f0.moreFragments)

        let f1 = FragmentInfo(byte: 0x82)
        XCTAssertEqual(f1.index, 2)
        XCTAssertTrue(f1.moreFragments)

        let last = FragmentInfo(byte: 0x05)
        XCTAssertEqual(last.index, 5)
        XCTAssertFalse(last.moreFragments)
    }

    func testThreeFragmentReassembly() async throws {
        let transport = MockTransport()
        let client = PickleLinkClient(transport: transport)
        let seq: UInt8 = 0 // first command — session starts at 0

        // Build three response frames for GET_HISTORY (cmd=0x10):
        //   frag0: status=SUCCESS, frag_info=0x80, payload 0xAA*100
        //   frag1: status=00 (ignored after first), frag_info=0x81, payload 0xBB*100
        //   frag2: status=00, frag_info=0x02 (no MORE), payload 0xCC*50
        let p0 = Data(repeating: 0xAA, count: 100)
        let p1 = Data(repeating: 0xBB, count: 100)
        let p2 = Data(repeating: 0xCC, count: 50)

        var f0 = Data([seq, 0x00, 0x80])
        f0.append(p0)
        var f1 = Data([seq, 0x00, 0x81])
        f1.append(p1)
        var f2 = Data([seq, 0x00, 0x02])
        f2.append(p2)

        // When the command write happens, deliver fragments.
        transport.onSend = { _ in
            Task {
                await client.ingestResponse(f0)
                await client.ingestResponse(f1)
                await client.ingestResponse(f2)
            }
        }

        let result = try await client.getHistory(page: 0, timeout: 2.0)

        XCTAssertEqual(result.count, 250)
        XCTAssertEqual(result.prefix(100), p0)
        XCTAssertEqual(result.subdata(in: 100 ..< 200), p1)
        XCTAssertEqual(result.suffix(50), p2)

        // Verify sent frame: [seq=0][cmd=0x10][page=0]
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0], Data([0x00, 0x10, 0x00]))
    }

    func testSingleFragmentPing() async throws {
        let transport = MockTransport()
        let client = PickleLinkClient(transport: transport)
        let seq: UInt8 = 0

        let ident = Data("pickle_smart 1.0".utf8)
        var resp = Data([seq, 0x00, 0x00])
        resp.append(ident)

        transport.onSend = { _ in
            Task { await client.ingestResponse(resp) }
        }

        let s = try await client.ping()
        XCTAssertEqual(s, "pickle_smart 1.0")
    }

    func testStatusErrorThrown() async {
        let transport = MockTransport()
        let client = PickleLinkClient(transport: transport)
        let seq: UInt8 = 0

        // status=0x05 NOT_CONFIGURED on the WAKEUP attempt.
        let resp = Data([seq, 0x05, 0x00])

        transport.onSend = { _ in
            Task { await client.ingestResponse(resp) }
        }

        do {
            try await client.wakeup()
            XCTFail("expected throw")
        } catch let e as SmartBridgeError {
            XCTAssertEqual(e, .statusError(.notConfigured, command: .wakeup))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testTimeoutFires() async {
        let transport = MockTransport()
        let client = PickleLinkClient(transport: transport, defaultTimeout: 0.2)
        // No onSend → no response delivered.
        do {
            _ = try await client.getBattery()
            XCTFail("expected timeout")
        } catch let e as SmartBridgeError {
            XCTAssertEqual(e, .timeout)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
