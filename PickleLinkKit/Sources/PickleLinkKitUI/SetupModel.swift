#if canImport(LoopKitUI) && canImport(CoreBluetooth)
    import Combine
    import CoreBluetooth
    import Foundation
    import LoopKit
    // MinimedKit не импортируется: PumpModel in-module PickleLinkKit (Medtronic/)
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
            // Отдельный restore-ID (аудит B6): у мастера настройки свой CBCentralManager.
            // С общим restore-ID два менеджера конфликтуют за state restoration (iOS
            // отдаёт восстановленные периферии одному — второй «слепнет»).
            bleManager = PickleLinkBLEManager(restoreIdentifier: "com.pickle.PickleLinkKit.central.setup")
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
            errorMessage = nil
            bleManager.stopScan()
            bleManager.connect(id: device.id)
            // Таймаут: если за 20с не ушли дальше .pairing (peripheralIsReady не сработал —
            // мост занят другим приложением или вне зоны), показываем ошибку вместо
            // вечного спиннера.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self else { return }
                if self.phase == .pairing, self.errorMessage == nil {
                    self.busy = false
                    self.errorMessage =
                        "Не удалось подключиться к мосту. Закройте другое приложение (iAPS), держащее мост, или подойдите ближе, и попробуйте снова."
                }
            }
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
            guard let c = client else { phase = .pumpID
                return }
            busy = true
            defer { busy = false }
            // Версию прошивки берём только для показа — НЕ блокируем добавление по ней.
            // Переходим к вводу номера помпы в любом случае (даже если ping не дошёл).
            firmwareVersion = try? await c.ping() // 0x13 (best-effort)
            phase = .pumpID
        }

        func configure(pumpID: String) async {
            guard let c = client else { return }
            busy = true
            defer { busy = false }
            // Единственное, что реально нужно для «добавить»: записать номер помпы в мост.
            // CONFIGURE_PUMP (0x01) — ЛОКАЛЬНАЯ команда моста (пишет pump_id в NVS),
            // радио до помпы НЕ требуется.
            do {
                try await c.configurePump(id: pumpID) // 0x01
            } catch {
                errorMessage = "CONFIGURE_PUMP failed: \(error)"
                return
            }
            // Частота и часы — best-effort, НЕ блокируют.
            try? await c.setFrequency(hz: 868_350_000) // 0x11
            try? await c.setClock() // 0x15
            // Модель помпы читаем best-effort (аудит C3): getModel (0x03) идёт до помпы по
            // радио и может упасть/затормозить при слабом сигнале — тогда фолбэк 722
            // (Paradigm 5/7-серия), чтобы не блокировать добавление. Реальную модель
            // подхватываем, когда радио доступно; сменить можно перенастройкой.
            if let raw = try? await c.getModel(),
               let s = PickleLinkConversions.medtronicModelString(fromRaw: raw),
               let m = PumpModel(rawValue: s)
            {
                pumpModel = m
            } else {
                pumpModel = .model722
            }
            phase = .frequency
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
