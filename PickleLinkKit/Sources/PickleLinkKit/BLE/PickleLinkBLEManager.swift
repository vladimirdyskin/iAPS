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

        // ОДИН активный коннект за раз. С несколькими одновременными коннектами мосты
        // глушат друг друга на радио помпы (коллизия 868 МГц) и BLE рвётся
        // (supervision timeout). Подключён ТОЛЬКО лучший мост; остальные — кандидаты,
        // их сигнал берём из скана. При обрыве/уходе из зоны — переключаемся на лучший.
        private var activeID: UUID?

        /// Включённые мосты-кандидаты = ПОЛЬЗОВАТЕЛЬСКИЕ тогглы. Выключенный тоггл
        /// исключает мост ПОЛНОСТЬЮ, даже если он закреплён как помпа. Если не выбран
        /// ни один (первый запуск) — закреплённая помпа как дефолт.
        private var enabledIDs: Set<UUID> {
            if !autoconnectIDs.isEmpty { return autoconnectIDs }
            if let p = pumpPeripheralID { return [p] }
            return []
        }

        /// Поставить pending-коннект ко ВСЕМ включённым мостам по UUID (retrievePeripherals,
        /// БЕЗ скана). `central.connect()` — pending: срабатывает в ФОНЕ/при блокировке,
        /// когда мост в зоне (скан в фоне iOS заглушает — поэтому реконнект через скан и
        /// ломал петлю при заблокированном телефоне). Реальный коннект придёт в didConnect;
        /// единственность держим там (лишние pending отменяются). При обрыве активного —
        /// заново pend всех → подхватится тот, что в зоне (роуминг работает и в фоне).
        private func connectAllEnabled() {
            guard activeID == nil else { return }
            for id in enabledIDs {
                let p = peripheralRefs[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
                guard let peripheral = p else { continue }
                peripheralRefs[id] = peripheral
                pendingConnectIDs.insert(id)
                central.connect(peripheral, options: nil)
            }
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
                // Новый кандидат. Pending-коннект ко всем включённым (если активного нет);
                // лишние отменятся в didConnect. В резерве подхватится при обрыве текущего.
                connectAllEnabled()
            } else {
                ids.remove(id)
                autoconnectIDs = ids
                disconnect(id: id) // если это активный — didDisconnect переключит на другой
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
            // allowDuplicates=false: ОБЯЗАТЕЛЬНО. С true CoreBluetooth шлёт didDiscover
            // десятки раз/сек на главную очередь → перестройка UI-списка → зависание
            // главного потока → watchdog-килл iAPS (0x8badf00d) → обрыв BLE (reason 19)
            // → «ошибка связи». Резерв получает RSSI один раз при старте скана — этого
            // достаточно для отображения сигнала, без флуда.
            central.scanForPeripherals(
                withServices: [PickleLinkUUIDs.service],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }

        public func stopScan() {
            central.stopScan()
        }

        public func connect(id: UUID) {
            // Единственный активный коннект — рвём все прочие перед новым.
            for (cid, plp) in connected where cid != id {
                central.cancelPeripheralConnection(plp.peripheral)
            }
            let p = peripheralRefs[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
            guard let peripheral = p else { startScan()
                return }
            peripheralRefs[id] = peripheral
            activeID = id
            pendingConnectIDs.insert(id)
            central.connect(peripheral, options: nil)
        }

        public func disconnect(id: UUID) {
            pendingConnectIDs.remove(id)
            if let plp = connected[id] {
                // Активный коннект — рвём; didDisconnectPeripheral дочистит и переключит.
                central.cancelPeripheralConnection(plp.peripheral)
            } else if let p = peripheralRefs[id] {
                // Только pending-попытка — отменяем. didDisconnect не придёт, чистим сами.
                central.cancelPeripheralConnection(p)
                if activeID == id {
                    activeID = nil
                    connectAllEnabled()
                }
            }
        }

        // MARK: - CBCentralManagerDelegate

        public func centralManagerDidUpdateState(_ central: CBCentralManager) {
            delegate?.bleManager(self, didUpdateState: central.state)
            // Реконнект — прямым pending-connect (работает в фоне/при блокировке), БЕЗ
            // скана. Скан нужен только для UI-списка устройств — его включает DataSource
            // при открытом экране настроек (isScanningEnabled).
            if central.state == .poweredOn {
                connectAllEnabled()
            }
        }

        public func centralManager(_: CBCentralManager, willRestoreState dict: [String: Any]) {
            guard let peris = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
            for p in peris {
                // Сильная ссылка обязательна — иначе CoreBluetooth молча уронит соединение.
                peripheralRefs[p.identifier] = p
                guard p.state == .connected || p.state == .connecting else { continue }
                // Один активный коннект: первый восстановленный делаем активным,
                // любые лишние — рвём.
                if let a = activeID, a != p.identifier {
                    central.cancelPeripheralConnection(p)
                    continue
                }
                activeID = p.identifier
                let plp = PickleLinkPeripheral(peripheral: p) // init ставит p.delegate = self
                connected[p.identifier] = plp
                discovered[p.identifier] = DiscoveredDevice(
                    id: p.identifier, name: p.name, rssi: 0,
                    discoveredAt: Date(), isConnected: p.state == .connected
                )
                // Поднять характеристики и сообщить PumpManager'у (создаст client, поставит
                // plp.delegate → peripheralIsReady → configurePump). Без этого восстановленное
                // соединение «висит» подключённым, но команды не идут — мост не отвечает.
                plp.discoverEverything()
                delegate?.bleManager(self, didConnect: plp)
            }
            // Восстановление после suspend/relaunch: если активного коннекта нет,
            // заново ставим pending-коннект ко всем включённым мостам. iOS перезапускает
            // приложение по BLE-событию (restoreIdentifier) — без этого pending-коннект
            // не восстанавливается, мост не переподключается в фоне, петля стоит.
            connectAllEnabled()
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
            // Активного нет, а это включённый мост в зоне — подключаемся к нему.
            if activeID == nil, enabledIDs.contains(peripheral.identifier) {
                connect(id: peripheral.identifier)
            }
        }

        public func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
            pendingConnectIDs.remove(peripheral.identifier)
            // Подключился мост, который НЕ включён тогглом (гонка: тоггл выключили, пока
            // pending-коннект был в полёте). Отклоняем — активным держим только
            // включённый мост, иначе UI «перевёрнут» (выключенный показан активным).
            guard enabledIDs.contains(peripheral.identifier) else {
                central.cancelPeripheralConnection(peripheral)
                if activeID == peripheral.identifier { activeID = nil }
                connectAllEnabled()
                return
            }
            activeID = peripheral.identifier
            // Скан НЕ останавливаем — резервные мосты должны показывать живой RSSI
            // (иначе их значок «перечёркнут»). Один коннект + скан стабильны.
            // Подчистить любые прочие коннекты — держим строго один.
            for (cid, plp) in connected where cid != peripheral.identifier {
                central.cancelPeripheralConnection(plp.peripheral)
            }
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
            // Не достучались — освобождаем слот и заново ставим pending-коннект ко всем
            // включённым (фоновый, без скана). central.connect() сам ждёт появления моста
            // в зоне без тайт-лупа — повторных мгновенных didFailToConnect не будет.
            if peripheral.identifier == activeID { activeID = nil }
            connectAllEnabled()
        }

        public func centralManager(
            _: CBCentralManager,
            didDisconnectPeripheral peripheral: CBPeripheral,
            error: Error?
        )
        {
            connected.removeValue(forKey: peripheral.identifier)
            discovered[peripheral.identifier]?.isConnected = false
            delegate?.bleManager(self, didDisconnect: peripheral.identifier, error: error)
            delegate?.bleManager(self, didUpdateDiscovered: Array(discovered.values))
            // Обрыв активного (ушёл из зоны / supervision timeout) — заново ставим
            // pending-коннект ко ВСЕМ включённым. Работает в ФОНЕ/при блокировке:
            // подхватится тот мост, что в зоне (роуминг переключением, без скана).
            if peripheral.identifier == activeID {
                activeID = nil
                connectAllEnabled()
            }
        }
    }
#endif
