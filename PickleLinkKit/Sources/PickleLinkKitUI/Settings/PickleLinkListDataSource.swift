#if canImport(SwiftUI) && canImport(LoopKitUI) && canImport(CoreBluetooth)
    import CoreBluetooth
    import PickleLinkKit
    import SwiftUI

    /// Источник данных для списка BLE-мостов в Settings.
    /// Аналог RileyLinkListDataSource. Использует bleManager из PumpManager —
    /// второй CBCentralManager не создаётся.
    /// Слушает NotificationCenter (PickleLinkDiscoveredDevicesDidChange) вместо того,
    /// чтобы быть делегатом BLEManager (делегат уже занят PumpManager).
    public final class PickleLinkListDataSource: ObservableObject {
        // MARK: Устройство для отображения в UI

        public struct BridgeDevice: Identifiable {
            public let id: UUID
            public let name: String
            public var rssi: Int?
            public var isConnected: Bool
        }

        @Published public private(set) var devices: [BridgeDevice] = []

        private let pumpManager: PickleLinkPumpManager

        private var bleManager: PickleLinkBLEManager { pumpManager.bleManager }

        private var rssiFetchTimer: Timer? {
            willSet { rssiFetchTimer?.invalidate() }
        }

        // MARK: Init

        public init(pumpManager: PickleLinkPumpManager) {
            self.pumpManager = pumpManager
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleDevicesUpdate),
                name: .PickleLinkDiscoveredDevicesDidChange,
                object: pumpManager
            )
            reloadDevices()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: Scanning

        public var isScanningEnabled: Bool = false {
            didSet {
                if isScanningEnabled {
                    bleManager.startScan()
                    rssiFetchTimer = Timer.scheduledTimer(
                        withTimeInterval: 3,
                        repeats: true
                    ) { [weak self] _ in self?.bleManager.updateRSSI() }
                    bleManager.updateRSSI()
                } else {
                    bleManager.stopScan()
                    rssiFetchTimer = nil
                }
            }
        }

        // MARK: Autoconnect binding

        /// Binding для Toggle «автоподключение» конкретного моста.
        public func autoconnectBinding(for id: UUID) -> Binding<Bool> {
            Binding(
                get: { [weak self] in self?.bleManager.shouldConnect(id: id) ?? false },
                set: { [weak self] enabled in self?.bleManager.setAutoconnect(id: id, enabled) }
            )
        }

        // MARK: Приватные методы

        @objc private func handleDevicesUpdate(_: Notification) {
            DispatchQueue.main.async { [weak self] in self?.reloadDevices() }
        }

        private func reloadDevices() {
            devices = bleManager.discovered.values.map { dev in
                BridgeDevice(
                    id: dev.id,
                    name: dev.name ?? "PickleLink",
                    rssi: dev.rssi == 0 ? nil : dev.rssi,
                    isConnected: dev.isConnected
                )
            }.sorted { $0.name < $1.name }
        }
    }
#endif
