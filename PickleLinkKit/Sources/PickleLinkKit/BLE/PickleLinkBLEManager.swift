import Foundation
#if canImport(CoreBluetooth)
    import CoreBluetooth

    public struct DiscoveredDevice: Equatable {
        public let id: UUID
        public let name: String?
        public let rssi: Int
        public let discoveredAt: Date
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
            let dev = DiscoveredDevice(
                id: peripheral.identifier,
                name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                rssi: RSSI.intValue,
                discoveredAt: Date()
            )
            peripheralRefs[peripheral.identifier] = peripheral
            discovered[dev.id] = dev
            delegate?.bleManager(self, didUpdateDiscovered: Array(discovered.values))
        }

        public func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
            pendingConnectIDs.remove(peripheral.identifier)
            let plp = PickleLinkPeripheral(peripheral: peripheral)
            connected[peripheral.identifier] = plp
            plp.discoverEverything()
            delegate?.bleManager(self, didConnect: plp)
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
            delegate?.bleManager(self, didDisconnect: peripheral.identifier, error: error)
            // Auto-reconnect: simple immediate reconnect attempt.
            central.connect(peripheral, options: nil)
        }
    }
#endif
