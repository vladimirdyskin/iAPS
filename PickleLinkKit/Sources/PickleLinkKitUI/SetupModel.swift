#if canImport(LoopKitUI) && canImport(CoreBluetooth)
    import Combine
    import CoreBluetooth
    import Foundation
    import LoopKit
    import MinimedKit
    import PickleLinkKit

    @MainActor final class PickleLinkSetupModel: ObservableObject {
        enum Phase {
            case scanning
            case pairing
            case pumpID
            case frequency
            case complete
        }

        @Published var phase: Phase = .scanning
        @Published var devices: [DiscoveredDevice] = []
        @Published var selectedDevice: DiscoveredDevice?
        @Published var firmwareVersion: String?
        @Published var pumpModel: PumpModel?
        @Published var errorMessage: String?
        @Published var busy: Bool = false

        var maxBasalRateUnitsPerHour: Double = 0
        var maxBolusUnits: Double = 0
        var basalSchedule: BasalRateSchedule?
        var insulinType: InsulinType = .novolog

        let bleManager: PickleLinkBLEManager
        private(set) var client: PickleLinkClient?
        private var peripheral: PickleLinkPeripheral?
        private let bridge = SetupBLEBridge()

        init() {
            bleManager = PickleLinkBLEManager()
            bridge.model = self
            bleManager.delegate = bridge
        }

        func startScan() { phase = .scanning
            bleManager.startScan() }

        func stopScan() { bleManager.stopScan() }

        func connect(_ device: DiscoveredDevice) {
            selectedDevice = device
            phase = .pairing
            busy = true
            bleManager.stopScan()
            bleManager.connect(id: device.id)
        }

        // Called by the BLE bridge.
        func didConnect(_ p: PickleLinkPeripheral) {
            peripheral = p
            let c = PickleLinkClient(transport: p)
            client = c
            // Wire transport→client glue for the setup session.
            bridge.client = c
        }

        func verifyFirmware() async {
            guard let c = client else { return }
            busy = true
            defer { busy = false }
            do {
                let v = try await c.ping() // 0x13
                firmwareVersion = v
                guard v.hasPrefix("pickle_smart") else {
                    errorMessage = "Unexpected firmware: \(v)"
                    return
                }
                phase = .pumpID
            } catch {
                errorMessage = "PING failed: \(error)"
            }
        }

        func configure(pumpID: String) async {
            guard let c = client else { return }
            busy = true
            defer { busy = false }
            do {
                try await c.configurePump(id: pumpID) // 0x01
                try? await c.setFrequency(hz: 868_350_000) // 0x11 — рабочая частота 868.35 МГц ДО чтения модели
                let raw = try await c.getModel() // 0x03
                guard let modelStr = PickleLinkConversions.medtronicModelString(fromRaw: raw),
                      let model = PumpModel(rawValue: modelStr)
                else {
                    errorMessage = "Unrecognised pump model (0x\(String(raw, radix: 16)))"
                    return
                }
                pumpModel = model
                // Синхронизируем часы помпы при настройке (SCMD 0x15 SET_CLOCK).
                try? await c.setClock() // 0x15 — не блокирует онбординг при ошибке
                phase = .frequency
            } catch {
                errorMessage = "CONFIGURE_PUMP failed: \(error)"
            }
        }

        func setFrequency(hz: UInt32?) async {
            if let hz, let c = client {
                busy = true
                defer { busy = false }
                try? await c.setFrequency(hz: hz) // 0x11
            }
            phase = .complete
        }

        func makeState() -> PickleLinkPumpManagerState? {
            guard let model = pumpModel, let device = selectedDevice else { return nil }
            var s = PickleLinkPumpManagerState(
                isOnboarded: true,
                pumpID: lastPumpID,
                peripheralIdentifier: device.id,
                pumpModel: model,
                frequencyHz: nil,
                timeZone: .current,
                suspendState: .resumed(Date()),
                insulinType: insulinType
            )
            s.isOnboarded = true
            return s
        }

        var lastPumpID: String = ""
    }

    /// Bridges the non-Sendable CoreBluetooth delegate callbacks onto the main actor.
    private final class SetupBLEBridge: NSObject, PickleLinkBLEManagerDelegate, PickleLinkPeripheralDelegate {
        weak var model: PickleLinkSetupModel?
        var client: PickleLinkClient?

        func bleManager(_ m: PickleLinkBLEManager, didUpdateState state: CBManagerState) {
            // CBCentralManager инициализируется асинхронно. startScan() из onAppear
            // мог прийти ДО poweredOn и молча выйти по guard — перезапускаем скан,
            // когда BLE реально готов (иначе «Поиск...» висит вечно).
            if state == .poweredOn { m.startScan() }
        }

        func bleManager(_: PickleLinkBLEManager, didUpdateDiscovered devices: [DiscoveredDevice]) {
            Task { @MainActor in self.model?.devices = devices.sorted { $0.rssi > $1.rssi } }
        }

        func bleManager(_: PickleLinkBLEManager, didConnect peripheral: PickleLinkPeripheral) {
            peripheral.delegate = self
            Task { @MainActor in self.model?.didConnect(peripheral) }
        }

        func bleManager(_: PickleLinkBLEManager, didDisconnect _: UUID, error _: Error?) {
            Task { @MainActor in self.model?.busy = false }
        }

        func peripheralIsReady(_: PickleLinkPeripheral) {
            Task { @MainActor in
                self.model?.busy = false
                await self.model?.verifyFirmware()
            }
        }

        func peripheral(_: PickleLinkPeripheral, didReceiveResponse data: Data) {
            let c = client
            Task { await c?.ingestResponse(data) }
        }

        func peripheral(_: PickleLinkPeripheral, didReceiveStatusEvent _: StatusEvent) {}
        func peripheral(_: PickleLinkPeripheral, didFailWith error: Error) {
            Task { @MainActor in self.model?.errorMessage = String(describing: error) }
        }

        // RSSI во время онбординга не нужен
        func peripheral(_: PickleLinkPeripheral, didReadRSSI _: Int) {}
    }
#endif
