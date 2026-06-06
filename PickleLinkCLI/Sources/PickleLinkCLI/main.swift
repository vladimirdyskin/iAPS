import CoreBluetooth
import Foundation
import PickleLinkKit

// PickleLink Smart Bridge BLE test harness.
//
// Usage:
//   swift run PickleLinkCLI [pumpID] [--name NRF]
//
//   pumpID    6-digit Medtronic serial (optional). If given, runs
//             CONFIGURE_PUMP + the pump read commands. Without it,
//             only device-level commands (PING / GET_STATISTICS).
//   --name X  connect to first device whose advertised name contains X
//             (default "NRF").
//
// Keeps a RunLoop alive because CoreBluetooth is callback-driven.

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(s)")
}

final class Harness: PickleLinkBLEManagerDelegate, PickleLinkPeripheralDelegate {
    let manager: PickleLinkBLEManager
    let nameFilter: String
    let pumpID: String?

    var client: PickleLinkClient?
    var connectedPeripheral: PickleLinkPeripheral?
    var didStartScan = false

    init(nameFilter: String, pumpID: String?) {
        self.nameFilter = nameFilter
        self.pumpID = pumpID
        manager = PickleLinkBLEManager(restoreIdentifier: "com.pickle.cli")
        manager.delegate = self
    }

    // MARK: BLE manager

    func bleManager(_ m: PickleLinkBLEManager, didUpdateState state: CBManagerState) {
        log("BLE state: \(state.rawValue) (\(stateName(state)))")
        if state == .poweredOn, !didStartScan {
            didStartScan = true
            log("Scanning for PickleLink service (filter name~\"\(nameFilter)\")…")
            m.startScan()
        } else if state == .unauthorized {
            log("ERROR: Bluetooth not authorized. Grant the terminal app Bluetooth access in System Settings › Privacy.")
            exit(2)
        }
    }

    func bleManager(_ m: PickleLinkBLEManager, didUpdateDiscovered devices: [DiscoveredDevice]) {
        guard connectedPeripheral == nil else { return }
        for d in devices {
            let name = d.name ?? "<no name>"
            if name.localizedCaseInsensitiveContains(nameFilter) {
                log("Found \(name) rssi=\(d.rssi) id=\(d.id). Connecting…")
                m.stopScan()
                m.connect(id: d.id)
                return
            }
        }
        log("Discovered \(devices.count) device(s), none matching \"\(nameFilter)\" yet…")
    }

    func bleManager(_: PickleLinkBLEManager, didConnect peripheral: PickleLinkPeripheral) {
        log("Connected. Discovering GATT…")
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverEverything()
    }

    func bleManager(_: PickleLinkBLEManager, didDisconnect id: UUID, error: Error?) {
        log("Disconnected id=\(id) error=\(String(describing: error))")
        exit(error == nil ? 0 : 1)
    }

    // MARK: Peripheral

    func peripheralIsReady(_ p: PickleLinkPeripheral) {
        log("GATT ready. Building client + running command sequence.")
        let c = PickleLinkClient(transport: p)
        client = c
        Task { await runSequence(c) }
    }

    func peripheral(_: PickleLinkPeripheral, didReceiveResponse data: Data) {
        if let c = client {
            Task { await c.ingestResponse(data) }
        }
    }

    func peripheral(_: PickleLinkPeripheral, didReceiveStatusEvent event: StatusEvent) {
        log("STATUS EVENT: \(event)")
    }

    func peripheral(_: PickleLinkPeripheral, didFailWith error: Error) {
        log("Peripheral error: \(error)")
    }

    // MARK: Command sequence

    func runSequence(_ c: PickleLinkClient) async {
        do {
            let version = try await c.ping()
            log("PING -> \"\(version)\"")
            guard version.hasPrefix("pickle_smart") else {
                log("Unexpected firmware identity. Aborting.")
                exit(3)
            }

            let stats = try await c.getStatistics()
            log("GET_STATISTICS -> \(stats)")

            if let id = pumpID {
                try await c.configurePump(id: id)
                log("CONFIGURE_PUMP(\(id)) -> OK")

                // Retry wakeup: on-device mmtune kicks in after 3 consecutive
                // radio errors, so allow at least that many attempts.
                let maxWakeup = 8
                var wokeUp = false
                for attempt in 1 ... maxWakeup {
                    do {
                        try await c.wakeup()
                        log("WAKEUP -> OK (attempt \(attempt))")
                        wokeUp = true
                        break
                    } catch {
                        log("WAKEUP attempt \(attempt)/\(maxWakeup) failed: \(error)")
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                guard wokeUp else {
                    log("Pump did not wake after \(maxWakeup) attempts — RF/freq issue. ❌")
                    exit(1)
                }

                let model = try await c.getModel()
                log("GET_MODEL -> \(model)")

                let batt = try await c.getBattery()
                log("GET_BATTERY -> \(batt)")

                let st = try await c.getStatus()
                log("GET_STATUS -> \(st)")

                let res = try await c.getReservoir()
                log("GET_RESERVOIR -> \(res)")

                let hi = try await c.getHistoryInfo()
                log("GET_HISTORY_INFO -> \(hi)")
            } else {
                log("No pumpID arg — skipping pump commands. Pass a 6-digit serial to test pump RF.")
            }

            log("Sequence complete. ✅")
        } catch {
            log("Sequence FAILED: \(error)")
            exit(1)
        }
        exit(0)
    }

    func stateName(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "?"
        }
    }
}

// ===== Wide BLE scan (list nearby devices, then exit) =====
final class WideScanner: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var seen: [UUID: (name: String, rssi: Int, svcs: [CBUUID])] = [:]
    let duration: TimeInterval

    init(duration: TimeInterval = 10) {
        self.duration = duration
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn {
            log("SCAN scanning all peripherals for \(Int(duration))s…")
            c.scanForPeripherals(
                withServices: nil,
                options:
                [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                self?.finish()
            }
        } else if c.state == .unauthorized {
            log("SCAN unauthorized BT")
            exit(2)
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover p: CBPeripheral,
        advertisementData ad: [String: Any],
        rssi: NSNumber
    ) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let svcs = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let r = rssi.intValue
        if let prev = seen[p.identifier] {
            seen[p.identifier] = (
                prev.name.isEmpty ? name : prev.name,
                max(prev.rssi, r),
                Array(Set(prev.svcs + svcs))
            )
        } else {
            seen[p.identifier] = (name, r, svcs)
        }
    }

    func finish() {
        central.stopScan()
        log("SCAN found \(seen.count) device(s):")
        let sorted = seen.sorted { $0.value.rssi > $1.value.rssi }
        for (id, info) in sorted {
            let n = info.name.isEmpty ? "<no name>" : info.name
            let s = info.svcs.map(\.uuidString).joined(separator: ",")
            print("  rssi=\(info.rssi) name=\(n) services=[\(s)] id=\(id)")
        }
        exit(0)
    }
}

// ===== Raw GATT probe (pure CoreBluetooth, no PickleLinkKit) =====
// Scans WITHOUT service filter (more reliable on macOS), connects by
// name, dumps every service + characteristic + properties, then exits.
final class GattProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    let nameFilter: String
    var target: CBPeripheral?
    var pendingServices = 0
    var pendingReads = 0
    // UUIDs которые читаем, если найдём, чтобы определить прошивку
    let readUUIDs: Set<CBUUID> = [
        CBUUID(string: "30D99DC9-7C91-4295-A051-0A104D238CF2"), // FW Version
        CBUUID(string: "D93B2AF0-1E28-11E4-8C21-0800200C9A66") // Custom Name
    ]

    init(nameFilter: String) {
        self.nameFilter = nameFilter
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("PROBE BLE state: \(c.state.rawValue)")
        if c.state == .poweredOn {
            log("PROBE scanning ALL peripherals (no service filter)…")
            c.scanForPeripherals(
                withServices: nil,
                options:
                [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        } else if c.state == .unauthorized {
            log("PROBE ERROR: Bluetooth unauthorized — grant terminal BT access.")
            exit(2)
        }
    }

    func centralManager(
        _ c: CBCentralManager,
        didDiscover p: CBPeripheral,
        advertisementData ad: [String: Any],
        rssi: NSNumber
    ) {
        let adv = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        // Exact case-insensitive match — NRF не должен матчить NRF69 и наоборот.
        let names = [adv, p.name ?? ""]
        guard target == nil, names.contains(where: { $0.caseInsensitiveCompare(nameFilter) == .orderedSame }) else { return }
        let svcs = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        log("PROBE found \"\(adv.isEmpty ? (p.name ?? "?") : adv)\" rssi=\(rssi) advServices=\(svcs.map(\.uuidString))")
        target = p
        p.delegate = self
        c.stopScan()
        c.connect(p, options: nil)
    }

    func centralManager(_: CBCentralManager, didConnect p: CBPeripheral) {
        log("PROBE connected. Discovering ALL services…")
        p.discoverServices(nil)
    }

    func centralManager(_: CBCentralManager, didFailToConnect _: CBPeripheral, error: Error?) {
        log("PROBE didFailToConnect: \(String(describing: error))")
        exit(1)
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral _: CBPeripheral, error: Error?) {
        log("PROBE disconnected: \(String(describing: error))")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { log("PROBE didDiscoverServices ERROR: \(e)")
            exit(1) }
        let svcs = p.services ?? []
        log("PROBE services count=\(svcs.count)")
        pendingServices = svcs.count
        if svcs.isEmpty { log("PROBE: NO SERVICES exposed by firmware ❌")
            exit(0) }
        for s in svcs {
            log("PROBE service \(s.uuid.uuidString)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if let e = error { log("PROBE chars ERROR for \(s.uuid): \(e)") }
        for ch in s.characteristics ?? [] {
            log("PROBE   char \(ch.uuid.uuidString) props=\(propStr(ch.properties))")
            if readUUIDs.contains(ch.uuid), ch.properties.contains(.read) {
                pendingReads += 1
                p.readValue(for: ch)
            }
        }
        pendingServices -= 1
        if pendingServices <= 0 {
            log("PROBE chars done — waiting \(pendingReads) reads…")
            if pendingReads == 0 { log("PROBE complete. ✅")
                exit(0) }
        }
    }

    func peripheral(_: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { log("PROBE read ERROR \(ch.uuid): \(e)") }
        else if let d = ch.value {
            let s = String(data: d, encoding: .utf8) ?? d.map { String(format: "%02X", $0) }.joined(separator: " ")
            log("PROBE READ \(ch.uuid.uuidString) -> \"\(s)\"")
        }
        pendingReads -= 1
        if pendingServices <= 0, pendingReads <= 0 {
            log("PROBE complete. ✅")
            exit(0)
        }
    }

    func propStr(_ p: CBCharacteristicProperties) -> String {
        var r = [String]()
        if p.contains(.read) { r.append("read") }
        if p.contains(.write) { r.append("write") }
        if p.contains(.writeWithoutResponse) { r.append("writeNR") }
        if p.contains(.notify) { r.append("notify") }
        if p.contains(.indicate) { r.append("indicate") }
        return r.joined(separator: "|")
    }
}

// ---- arg parsing ----
var args = Array(CommandLine.arguments.dropFirst())
var nameFilter = "NRF"
var pumpID: String?
var probeMode = false
var scanMode = false
var i = 0
while i < args.count {
    let a = args[i]
    if a == "--name", i + 1 < args.count {
        nameFilter = args[i + 1]
        i += 2
    } else if a == "--probe" {
        probeMode = true
        i += 1
    } else if a == "--scan" {
        scanMode = true
        i += 1
    } else if a.allSatisfy(\.isNumber), a.count == 6 {
        pumpID = a
        i += 1
    } else {
        log("Ignoring unknown arg: \(a)")
        i += 1
    }
}

log("PickleLink CLI harness. mode=\(probeMode ? "PROBE" : "client") nameFilter=\(nameFilter) pumpID=\(pumpID ?? "none")")

// Hold a strong ref so the delegate object isn't deallocated.
var probe: GattProbe?
var harness: Harness?
var scanner: WideScanner?
if scanMode {
    scanner = WideScanner(duration: 10)
} else if probeMode {
    probe = GattProbe(nameFilter: nameFilter)
} else {
    harness = Harness(nameFilter: nameFilter, pumpID: pumpID)
}

// Watchdog: bail if nothing happens in 90 s.
DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
    log("Timeout (90s) with no completion. Exiting.")
    exit(4)
}

RunLoop.main.run()
