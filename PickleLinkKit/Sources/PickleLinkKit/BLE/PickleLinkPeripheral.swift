import Foundation
#if canImport(CoreBluetooth)
    import CoreBluetooth

    /// Per-peripheral state. Discovers service+characteristics, subscribes to both notify chars,
    /// forwards bytes upward.
    public final class PickleLinkPeripheral: NSObject, CBPeripheralDelegate, CommandTransport, @unchecked Sendable {
        public weak var delegate: PickleLinkPeripheralDelegate?

        public let peripheral: CBPeripheral

        private var commandChar: CBCharacteristic?
        private var responseChar: CBCharacteristic?
        private var statusChar: CBCharacteristic?

        // pendingWrite трогается из двух потоков: sendCommand (исполнитель actor
        // CommandSession) и didWriteValueFor (main-очередь CBPeripheral). Без лока —
        // гонка и двойной resume CheckedContinuation = краш. Берём continuation
        // АТОМАРНО (swap на nil под локом), resume — ВНЕ лока, ровно один раз.
        private let writeLock = NSLock()
        private var pendingWrite: CheckedContinuation<Void, Error>?
        private var didSignalReady = false
        private var discoveryStarted = false

        /// Атомарно забрать pendingWrite (swap на nil). Resume вызывать вне лока.
        private func takePendingWrite() -> CheckedContinuation<Void, Error>? {
            writeLock.lock()
            defer { writeLock.unlock() }
            let c = pendingWrite
            pendingWrite = nil
            return c
        }

        /// Провалить зависшую запись при обрыве (вызывается из PumpManager.didDisconnect).
        /// Без этого continuation pendingWrite утекает при разрыве в момент записи →
        /// send() висит вечно → слот команды держится → клин ВСЕХ команд.
        public func failPendingWrite() {
            takePendingWrite()?.resume(throwing: SmartBridgeError.notConnected)
        }

        public init(peripheral: CBPeripheral) {
            self.peripheral = peripheral
            super.init()
            peripheral.delegate = self
        }

        public var isReady: Bool {
            commandChar != nil && responseChar != nil && statusChar != nil
        }

        /// Idempotent — safe to call from multiple owners (BLE manager + delegate).
        public func discoverEverything() {
            if isReady { signalReadyOnce()
                return }
            guard !discoveryStarted else { return }
            discoveryStarted = true
            peripheral.discoverServices([PickleLinkUUIDs.service])
        }

        private func signalReadyOnce() {
            guard !didSignalReady else { return }
            didSignalReady = true
            delegate?.peripheralIsReady(self)
        }

        // MARK: - CommandTransport

        public func sendCommand(_ frame: Data) async throws {
            guard let ch = commandChar else { throw SmartBridgeError.characteristicsMissing }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // Атомарно: забрать прежний (stale) continuation и поставить новый.
                writeLock.lock()
                let stale = pendingWrite
                pendingWrite = cont
                writeLock.unlock()
                // resume — ВНЕ лока, ровно один раз (stale уже не доступен другим).
                stale?.resume(throwing: SmartBridgeError.notConnected)
                // WRITE with response — wait for didWriteValueFor callback.
                peripheral.writeValue(frame, for: ch, type: .withResponse)
            }
        }

        // MARK: - CBPeripheralDelegate

        public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
            guard error == nil else {
                delegate?.peripheral(self, didFailWith: error!)
                return
            }
            guard let svc = peripheral.services?.first(where: { $0.uuid == PickleLinkUUIDs.service }) else {
                delegate?.peripheral(self, didFailWith: SmartBridgeError.characteristicsMissing)
                return
            }
            peripheral.discoverCharacteristics(
                [PickleLinkUUIDs.command, PickleLinkUUIDs.response, PickleLinkUUIDs.status],
                for: svc
            )
        }

        public func peripheral(
            _ peripheral: CBPeripheral,
            didDiscoverCharacteristicsFor service: CBService,
            error: Error?
        )
        {
            guard error == nil else {
                delegate?.peripheral(self, didFailWith: error!)
                return
            }
            for ch in service.characteristics ?? [] {
                switch ch.uuid {
                case PickleLinkUUIDs.command: commandChar = ch
                case PickleLinkUUIDs.response: responseChar = ch
                    peripheral.setNotifyValue(true, for: ch)
                case PickleLinkUUIDs.status: statusChar = ch
                    peripheral.setNotifyValue(true, for: ch)
                default: break
                }
            }
            if isReady {
                signalReadyOnce()
            } else {
                delegate?.peripheral(self, didFailWith: SmartBridgeError.characteristicsMissing)
            }
        }

        public func peripheral(
            _: CBPeripheral,
            didUpdateValueFor characteristic: CBCharacteristic,
            error: Error?
        )
        {
            guard error == nil, let data = characteristic.value else { return }
            switch characteristic.uuid {
            case PickleLinkUUIDs.response:
                delegate?.peripheral(self, didReceiveResponse: data)
            case PickleLinkUUIDs.status:
                if let ev = StatusEvent(raw: data) {
                    delegate?.peripheral(self, didReceiveStatusEvent: ev)
                }
            default:
                break
            }
        }

        public func peripheral(
            _: CBPeripheral,
            didWriteValueFor _: CBCharacteristic,
            error: Error?
        )
        {
            let cont = takePendingWrite()
            if let error = error {
                cont?.resume(throwing: error)
            } else {
                cont?.resume()
            }
        }

        public func peripheral(_: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
            guard error == nil else { return }
            delegate?.peripheral(self, didReadRSSI: RSSI.intValue)
        }
    }

    public protocol PickleLinkPeripheralDelegate: AnyObject {
        func peripheralIsReady(_ p: PickleLinkPeripheral)
        func peripheral(_ p: PickleLinkPeripheral, didReceiveResponse data: Data)
        func peripheral(_ p: PickleLinkPeripheral, didReceiveStatusEvent event: StatusEvent)
        func peripheral(_ p: PickleLinkPeripheral, didFailWith error: Error)
        func peripheral(_ p: PickleLinkPeripheral, didReadRSSI rssi: Int)
    }
#endif
