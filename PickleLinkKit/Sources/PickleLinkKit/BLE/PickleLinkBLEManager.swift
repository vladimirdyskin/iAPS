import Foundation
import os.log
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

        /// Скан-фолбэк: если pending-`central.connect()` молчит 30с (iOS мог инвалидировать
        /// старый CBPeripheral после долгого отсутствия — «отошёл и вернулся»), включаем скан.
        /// В foreground didDiscover→connect подхватит мост; в фоне безвреден (pending остаётся
        /// основным). Отменяется при коннекте.
        private var reconnectScanWatchdog: DispatchWorkItem?

        /// true, пока активен именно скан-фолбэк реконнекта (запущен watchdog'ом ниже),
        /// а НЕ UI-скан из настроек. Позволяет погасить фолбэк-скан после успешного
        /// коннекта, не трогая UI-скан (аудит R5).
        private var fallbackScanActive = false

        /// Все мутации BLE-состояния должны идти на main-очереди — там же работают
        /// колбэки CBCentralManager (init с queue: nil). Публичные методы зовутся с
        /// processQueue/UI (аудит K3): без хопа гонка за discovered/connected/peripheralRefs.
        private func onMain(_ block: @escaping () -> Void) {
            if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
        }

        private func scheduleReconnectScanFallback() {
            reconnectScanWatchdog?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.activeID == nil, self.connected.isEmpty else { return }
                os_log("BLE pending silent 30s → scan fallback", log: Self.bleLog, type: .error)
                self.fallbackScanActive = true // это фолбэк-скан, гасим его в didConnect
                self.startScan() // didDiscover(enabled, activeID==nil) → connect()
            }
            reconnectScanWatchdog = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
        }

        /// Диагностика BLE-жизненного цикла (os_log). Снимается с устройства через
        /// `log collect`/sysdiagnose, фильтр: subsystem com.pickle.PickleLinkKit, category BLE.
        /// Нужна для разбора интермиттентных отвалов моста — пишет reason разрыва.
        private static let bleLog = OSLog(subsystem: "com.pickle.PickleLinkKit", category: "BLE")

        /// Расшифровка ошибки CoreBluetooth для лога: домен#код + текст (или "clean" если nil).
        private static func errStr(_ error: Error?) -> String {
            guard let e = error as NSError? else { return "clean" }
            return "\(e.domain)#\(e.code) \(e.localizedDescription)"
        }

        // CoreBluetooth silently drops connections if the CBPeripheral is not
        // strongly retained — keep discovered/connecting peripherals here.
        private var peripheralRefs: [UUID: CBPeripheral] = [:]

        /// Вызывается PumpManager при инициализации с закреплённым мостом помпы.
        /// ОДИН раз засевает его в autoconnect (тоггл ON по умолчанию), если автоконнект
        /// ещё ни разу не настраивался. Раньше дефолт давал скрытый fallback в enabledIDs
        /// → тоггл показывал OFF при подключённом мосте (рассинхрон). Флаг гарантирует
        /// «один раз»: дальше пользователь волен выключить всё.
        public func markAsPumpPeripheral(id: UUID) {
            let seededKey = "\(restoreID).autoconnectSeeded"
            guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
            if autoconnectIDs.isEmpty {
                autoconnectIDs = [id]
            }
            UserDefaults.standard.set(true, forKey: seededKey)
        }

        /// Сбрасывает память автоконнекта (аудит B1): и список включённых мостов, и флаг
        /// «уже засеяно». Вызывается при деактивации помпы — иначе протухший сид переживёт
        /// удаление и заблокирует подключение нового моста после переустановки.
        public func clearAutoconnectState() {
            onMain {
                UserDefaults.standard.removeObject(forKey: "\(self.restoreID).autoconnect")
                UserDefaults.standard.removeObject(forKey: "\(self.restoreID).autoconnectSeeded")
            }
        }

        // ОДИН активный коннект за раз. С несколькими одновременными коннектами мосты
        // глушат друг друга на радио помпы (коллизия 868 МГц) и BLE рвётся
        // (supervision timeout). Подключён ТОЛЬКО лучший мост; остальные — кандидаты,
        // их сигнал берём из скана. При обрыве/уходе из зоны — переключаемся на лучший.
        private var activeID: UUID?

        /// Включённые мосты = ПОЛЬЗОВАТЕЛЬСКИЕ тогглы (autoconnectIDs) — ЕДИНЫЙ источник
        /// истины и для коннекта, и для UI-тоггла (иначе рассинхрон: «выкл», но
        /// подключён). Дефолт (закреплённая помпа) задаётся ОДИН раз через seed в
        /// markAsPumpPeripheral, а не скрытым fallback здесь.
        private var enabledIDs: Set<UUID> { autoconnectIDs }

        /// Поставить pending-коннект ко ВСЕМ включённым мостам по UUID (retrievePeripherals,
        /// БЕЗ скана). `central.connect()` — pending: срабатывает в ФОНЕ/при блокировке,
        /// когда мост в зоне (скан в фоне iOS заглушает — поэтому реконнект через скан и
        /// ломал петлю при заблокированном телефоне). Реальный коннект придёт в didConnect;
        /// единственность держим там (лишние pending отменяются). При обрыве активного —
        /// заново pend всех → подхватится тот, что в зоне (роуминг работает и в фоне).
        private func connectAllEnabled() {
            guard activeID == nil else { return }
            var anyPending = false
            for id in enabledIDs {
                let p = peripheralRefs[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
                guard let peripheral = p else { continue }
                peripheralRefs[id] = peripheral
                pendingConnectIDs.insert(id)
                central.connect(peripheral, options: nil)
                anyPending = true
                os_log("BLE reconnect pending %{public}@", log: Self.bleLog, type: .info, id.uuidString)
            }
            // Поставили pending — подстрахуемся скан-фолбэком, если он молчит (дыра №2).
            if anyPending { scheduleReconnectScanFallback() }
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
            onMain {
                var ids = self.autoconnectIDs
                if enabled {
                    ids.insert(id)
                    self.autoconnectIDs = ids
                    // Новый кандидат. Pending-коннект ко всем включённым (если активного нет);
                    // лишние отменятся в didConnect. В резерве подхватится при обрыве текущего.
                    self.connectAllEnabled()
                } else {
                    ids.remove(id)
                    self.autoconnectIDs = ids
                    self.disconnect(id: id) // если это активный — didDisconnect переключит на другой
                }
            }
        }

        /// Запросить RSSI у всех подключённых периферий.
        /// Результат придёт через PickleLinkPeripheralDelegate.peripheral(_:didReadRSSI:).
        public func updateRSSI() {
            onMain {
                for (_, plp) in self.connected {
                    plp.peripheral.readRSSI()
                }
            }
        }

        /// Вызывается из PickleLinkPumpManager.peripheral(_:didReadRSSI:).
        /// Обновляет RSSI в discovered и уведомляет делегата (DataSource пересобирает список).
        public func updateDiscoveredRSSI(id: UUID, rssi: Int) {
            onMain {
                self.discovered[id]?.rssi = rssi
                self.delegate?.bleManager(self, didUpdateDiscovered: Array(self.discovered.values))
            }
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
            onMain {
                guard self.central.state == .poweredOn else { return }
                // allowDuplicates=false: ОБЯЗАТЕЛЬНО. С true CoreBluetooth шлёт didDiscover
                // десятки раз/сек на главную очередь → перестройка UI-списка → зависание
                // главного потока → watchdog-килл iAPS (0x8badf00d) → обрыв BLE (reason 19)
                // → «ошибка связи». Резерв получает RSSI один раз при старте скана — этого
                // достаточно для отображения сигнала, без флуда.
                self.central.scanForPeripherals(
                    withServices: [PickleLinkUUIDs.service],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
            }
        }

        public func stopScan() {
            onMain { self.central.stopScan() }
        }

        public func connect(id: UUID) {
            onMain {
                // Единственный активный коннект — рвём все прочие перед новым.
                for (cid, plp) in self.connected where cid != id {
                    self.central.cancelPeripheralConnection(plp.peripheral)
                }
                let p = self.peripheralRefs[id] ?? self.central.retrievePeripherals(withIdentifiers: [id]).first
                guard let peripheral = p else { self.startScan()
                    return }
                self.peripheralRefs[id] = peripheral
                self.activeID = id
                self.pendingConnectIDs.insert(id)
                self.central.connect(peripheral, options: nil)
            }
        }

        public func disconnect(id: UUID) {
            onMain {
                self.pendingConnectIDs.remove(id)
                if let plp = self.connected[id] {
                    // Активный коннект — рвём; didDisconnectPeripheral дочистит и переключит.
                    self.central.cancelPeripheralConnection(plp.peripheral)
                } else if let p = self.peripheralRefs[id] {
                    // Только pending-попытка — отменяем. didDisconnect не придёт, чистим сами.
                    self.central.cancelPeripheralConnection(p)
                    if self.activeID == id {
                        self.activeID = nil
                        self.connectAllEnabled()
                    }
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
            // Уже есть ЗДОРОВЫЙ активный коннект к ДРУГОМУ мосту — не воруем.
            // Это сработал лишний pending-коннект, поставленный connectAllEnabled, когда
            // активного ещё не было (central.connect висит бессрочно). Если его принять —
            // ping-pong: новичок отбирает active и рвёт рабочий мост (reason=19), в т.ч.
            // ПОСРЕДИ GET_HISTORY. Гасим новичка, активный не трогаем. Переключение на
            // другой мост — только при реальном обрыве активного (didDisconnect → roam).
            if let a = activeID, a != peripheral.identifier, connected[a] != nil {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            // Подключился мост, который НЕ включён тогглом (гонка: тоггл выключили, пока
            // pending-коннект был в полёте). Отклоняем — активным держим только
            // включённый мост, иначе UI «перевёрнут» (выключенный показан активным).
            // ИСКЛЮЧЕНИЕ: явный connect(id:) из мастера настройки/UI выставляет activeID
            // ДО коннекта — такой мост пропускаем независимо от тогглов (при ДОБАВЛЕНИИ
            // помпы он ещё не в autoconnect). Гасим только непрошеный автоконнект
            // (connectAllEnabled activeID не трогает → activeID != этот мост).
            guard enabledIDs.contains(peripheral.identifier) || activeID == peripheral.identifier else {
                central.cancelPeripheralConnection(peripheral)
                if activeID == peripheral.identifier { activeID = nil }
                connectAllEnabled()
                return
            }
            activeID = peripheral.identifier
            reconnectScanWatchdog?.cancel() // коннект пошёл — скан-фолбэк не нужен
            reconnectScanWatchdog = nil
            // Если это был именно фолбэк-скан реконнекта (аудит R5) — гасим его: коннект
            // поднялся, крутить радио скана больше незачем. UI-скан из настроек (флаг не
            // взведён) не трогаем — резервные мосты должны показывать живой RSSI.
            if fallbackScanActive {
                fallbackScanActive = false
                stopScan()
            }
            os_log("BLE connected %{public}@", log: Self.bleLog, type: .info, peripheral.identifier.uuidString)
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
            os_log(
                "BLE failToConnect %{public}@ err=%{public}@",
                log: Self.bleLog,
                type: .error,
                peripheral.identifier.uuidString,
                Self.errStr(error)
            )
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
            let wasActive = peripheral.identifier == activeID
            // reason пуст (clean) = локальный cancelPeripheralConnection (наш роуминг/disconnect);
            // непустой (напр. CBErrorDomain#7 peripheralDisconnected, #6 connectionTimeout) =
            // мост пропал/перезагрузился/supervision timeout. Ключевая улика отвала.
            os_log(
                "BLE DISCONNECT %{public}@ reason=%{public}@ wasActive=%{public}d",
                log: Self.bleLog,
                type: .error,
                peripheral.identifier.uuidString,
                Self.errStr(error),
                wasActive ? 1 : 0
            )
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
