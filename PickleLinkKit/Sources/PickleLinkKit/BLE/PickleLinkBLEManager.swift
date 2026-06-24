import Foundation
#if canImport(CoreBluetooth)
    import CoreBluetooth

    public struct DiscoveredDevice: Equatable {
        public let id: UUID
        public let name: String?
        public var rssi: Int
        public let discoveredAt: Date
        /// true если на данный момент есть активное BLE-соединение с этим устройством
        public var isConnected: Bool
    }

    public protocol PickleLinkBLEManagerDelegate: AnyObject {
        func bleManager(_ m: PickleLinkBLEManager, didUpdateState state: CBManagerState)
        func bleManager(_ m: PickleLinkBLEManager, didUpdateDiscovered devices: [DiscoveredDevice])
        func bleManager(_ m: PickleLinkBLEManager, didConnect peripheral: PickleLinkPeripheral)
        func bleManager(_ m: PickleLinkBLEManager, didDisconnect id: UUID, error: Error?)
    }

    /// CBCentralManager wrapper. Scans by service UUID, supports state restoration.
    public final class PickleLinkBLEManager: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
        public weak var delegate: PickleLinkBLEManagerDelegate?

        private var central: CBCentralManager!
        public private(set) var discovered: [UUID: DiscoveredDevice] = [:]
        public private(set) var connected: [UUID: PickleLinkPeripheral] = [:]

        private let restoreID: String
        private var pendingConnectIDs: Set<UUID> = []
        // CoreBluetooth silently drops connections if the CBPeripheral is not
        // strongly retained — keep discovered/connecting peripherals here.
        private var peripheralRefs: [UUID: CBPeripheral] = [:]

        // UUID «главного» периферийного устройства (активная помпа).
        // Реконнектится при обрыве вне зависимости от UI-тоггла autoconnect.
        private var pumpPeripheralID: UUID?

        /// Вызывается PumpManager при инициализации, чтобы пометить мост активной помпы.
        /// Этот id всегда переподключается при обрыве.
        public func markAsPumpPeripheral(id: UUID) {
            pumpPeripheralID = id
        }

        // MARK: - Autoconnect memory

        // Набор UUID, которые пользователь пометил «автоподключать».
        // Хранится в UserDefaults под ключом, привязанным к restoreID.
        private var autoconnectIDs: Set<UUID> {
            get {
                let key = "\(restoreID).autoconnect"
                let strings = UserDefaults.standard.stringArray(forKey: key) ?? []
                return Set(strings.compactMap { UUID(uuidString: $0) })
            }
            set {
                let key = "\(restoreID).autoconnect"
                UserDefaults.standard.set(newValue.map(\.uuidString), forKey: key)
            }
        }

        public func shouldConnect(id: UUID) -> Bool {
            autoconnectIDs.contains(id)
        }

        public func setAutoconnect(id: UUID, _ enabled: Bool) {
            var ids = autoconnectIDs
            if enabled {
                ids.insert(id)
                autoconnectIDs = ids
                connect(id: id)
            } else {
                ids.remove(id)
                autoconnectIDs = ids
                disconnect(id: id)
            }
        }

        /// Запросить RSSI у всех подключённых периферий.
        /// Результат придёт через PickleLinkPeripheralDelegate.peripheral(_:didReadRSSI:).
        public func updateRSSI() {
            for (_, plp) in connected {
                plp.peripheral.readRSSI()
            }
        }

        /// Вызывается из PickleLinkPumpManager.peripheral(_:didReadRSSI:).
        /// Обновляет RSSI в discovered и уведомляет делегата (DataSource пересобирает список).
        public func updateDiscoveredRSSI(id: UUID, rssi: Int) {
            discovered[id]?.rssi = rssi
            delegate?.bleManager(self, didUpdateDiscovered: Array(discovered.values))
        }

        public init(restoreIdentifier: String = "com.pickle.PickleLinkKit.central") {
            restoreID = restoreIdentifier
            super.init()
            let opts: [String: Any] = [
                CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: false
            ]
            central = CBCentralManager(delegate: self, queue: nil, options: opts)
        }

        // MARK: - Public API

        public func startScan() {
            guard central.state == .poweredOn else { return }
            central.scanForPeripherals(
                withServices: [PickleLinkUUIDs.service],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }

        public func stopScan() {
            central.stopScan()
        }

        public func connect(id: UUID) {
            let p = peripheralRefs[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
            guard let peripheral = p else { return }
            peripheralRefs[id] = peripheral
            pendingConnectIDs.insert(id)
            central.connect(peripheral, options: nil)
        }

        public func disconnect(id: UUID) {
            if let plp = connected[id] {
                central.cancelPeripheralConnection(plp.peripheral)
            }
        }

        // MARK: - CBCentralManagerDelegate

        public func centralManagerDidUpdateState(_ central: CBCentralManager) {
            delegate?.bleManager(self, didUpdateState: central.state)
        }

        public func centralManager(_: CBCentralManager, willRestoreState dict: [String: Any]) {
            if let peris = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
                for p in peris where p.state == .connected || p.state == .connecting {
                    let plp = PickleLinkPeripheral(peripheral: p)
                    connected[p.identifier] = plp
                }
            }
        }

        public func centralManager(
            _: CBCentralManager,
            didDiscover peripheral: CBPeripheral,
            advertisementData: [String: Any],
            rssi RSSI: NSNumber
        )
        {
            let alreadyConnected = connected[peripheral.identifier] != nil
            let dev = DiscoveredDevice(
                id: peripheral.identifier,
                name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                rssi: RSSI.intValue,
                discoveredAt: Date(),
                isConnected: alreadyConnected
            )
            peripheralRefs[peripheral.identifier] = peripheral
            discovered[dev.id] = dev
            delegate?.bleManager(self, didUpdateDiscovered: Array(discovered.values))
        }

        public func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
            pendingConnectIDs.remove(peripheral.identifier)
            let plp = PickleLinkPeripheral(peripheral: peripheral)
            connected[peripheral.identifier] = plp
            // Если устройство не было обнаружено через скан (например, мост помпы был
            // подключён через retrievePeripherals в init PumpManager, минуя didDiscover),
            // создаём запись в discovered вручную.
            if discovered[peripheral.identifier] != nil {
                discovered[peripheral.identifier]?.isConnected = true
            } else {
                discovered[peripheral.identifier] = DiscoveredDevice(
                    id: peripheral.identifier,
                    name: peripheral.name,
                    rssi: 0,
                    discoveredAt: Date(),
                    isConnected: true
                )
            }
            plp.discoverEverything()
            delegate?.bleManager(self, didConnect: plp)
            delegate?.bleManager(self, didUpdateDiscovered: Array(discovered.values))
        }

        public func centralManager(
            _: CBCentralManager,
            didFailToConnect peripheral: CBPeripheral,
            error: Error?
        )
        {
            pendingConnectIDs.remove(peripheral.identifier)
            delegate?.bleManager(self, didDisconnect: peripheral.identifier, error: error)
        }

        public func centralManager(
            _ central: CBCentralManager,
            didDisconnectPeripheral peripheral: CBPeripheral,
            error: Error?
        )
        {
            connected.removeValue(forKey: peripheral.identifier)
            discovered[peripheral.identifier]?.isConnected = false
            delegate?.bleManager(self, didDisconnect: peripheral.identifier, error: error)
            delegate?.bleManager(self, didUpdateDiscovered: Array(discovered.values))
            // Auto-reconnect: мост активной помпы реконнектится всегда;
            // остальные устройства — только если помечены пользователем через UI.
            if peripheral.identifier == pumpPeripheralID || shouldConnect(id: peripheral.identifier) {
                central.connect(peripheral, options: nil)
            }
        }
    }
#endif
