#if canImport(SwiftUI) && canImport(LoopKitUI)
    import LoopKitUI
    import PickleLinkKit
    import SwiftUI

    // MARK: - Detail View

    /// Детальный экран устройства PickleLink. Паритет с RileyLinkDeviceTableViewController.
    /// Открывается по тапу на строку устройства в PickleLinkNativeSettingsView.
    struct PickleLinkDeviceDetailView: View {
        // Устройство из DataSource (имя, UUID, начальный RSSI, isConnected).
        let device: PickleLinkListDataSource.BridgeDevice
        let pumpManager: PickleLinkPumpManager

        // MARK: State

        @State private var rssi: Int?
        @State private var firmwareVersion: String?
        @State private var firmwareLoading = false
        @State private var stats: DeviceStatistics?
        @State private var statsLoading = false
        @State private var identifyLoading = false
        @State private var errorMessage: String?

        private let rssiTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

        // MARK: Body

        var body: some View {
            Form {
                deviceSection
                pumpRadioSection
                firmwareSection
                bridgeSection
            }
            .navigationTitle(device.name)
            .onAppear { fetchOnOpen() }
            .onReceive(rssiTimer) { _ in updateRSSI() }
        }

        // MARK: - Секция: Устройство

        private var deviceSection: some View {
            Section(header: Text("Устройство")) {
                deviceNameRow
                rssiRow
                connectionStateRow
                uuidRow
            }
        }

        private var deviceNameRow: some View {
            LabeledValueView(label: "Имя", value: device.name)
        }

        private var rssiRow: some View {
            HStack {
                Text("Сигнал")
                Spacer()
                if let r = rssi ?? device.rssi {
                    Text("\(r) dBm")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            }
        }

        private var connectionStateRow: some View {
            HStack {
                Text("Состояние")
                Spacer()
                // Проверяем текущее подключение через activeBridgeUUID, т.к. BridgeDevice.isConnected
                // снимок на момент открытия. activeBridgeUUID — live из менеджера.
                let connected = pumpManager.activeBridgeUUID == device.id
                Text(connected ? "Подключён" : "Резерв")
                    .foregroundStyle(connected ? .primary : .secondary)
            }
        }

        private var uuidRow: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text("UUID")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(device.id.uuidString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        }

        // MARK: - Секция: Помпа / Радио

        private var pumpRadioSection: some View {
            Section(header: Text("Помпа / Радио")) {
                LabeledValueView(label: "Pump ID", value: pumpManager.state.pumpID)
                LabeledValueView(label: "Модель", value: pumpManager.state.pumpModel.rawValue)
                if let hz = pumpManager.state.frequencyHz {
                    LabeledValueView(
                        label: "Частота",
                        value: String(format: "%.3f MHz", Double(hz) / 1_000_000)
                    )
                } else {
                    HStack {
                        Text("Частота")
                        Spacer()
                        Text("авто (mmtune)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        // MARK: - Секция: Прошивка

        private var firmwareSection: some View {
            Section(header: Text("Прошивка")) {
                if isActiveDevice {
                    if firmwareLoading {
                        HStack {
                            Text("Версия")
                            Spacer()
                            ProgressView()
                        }
                    } else if let v = firmwareVersion {
                        LabeledValueView(label: "Версия", value: v)
                    } else {
                        HStack {
                            Text("Версия")
                            Spacer()
                            Text("—")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    unavailableRow
                }
            }
        }

        // MARK: - Секция: Мост

        private var bridgeSection: some View {
            Section(header: Text("Мост")) {
                if isActiveDevice {
                    if statsLoading && stats == nil {
                        HStack { ProgressView().frame(maxWidth: .infinity) }
                    } else if let s = stats {
                        LabeledValueView(label: "Батарея", value: "\(s.batteryPct)% · \(s.batteryMv) mV")
                        LabeledValueView(label: "RX пакетов", value: "\(s.rxCount)")
                        LabeledValueView(label: "TX (wrap 255)", value: "\(s.txCount)")
                        // Uptime: присутствует в прошивке v1.2.0+; nil для старых мостов.
                        LabeledValueView(
                            label: "Uptime",
                            value: s.uptimeSeconds.map { formatUptime($0) } ?? "—"
                        )
                    }
                    // Кнопка «Обновить» всегда (если подключён, даже если stats nil).
                    Button {
                        Task { await fetchStats() }
                    } label: {
                        HStack {
                            Text("Обновить")
                            if statsLoading { ProgressView() }
                        }
                    }
                    .disabled(statsLoading)
                    // Кнопка «Найти устройство» — identify (LED мигает ~2 сек).
                    Button {
                        Task { await identify() }
                    } label: {
                        HStack {
                            Text("Найти устройство")
                            if identifyLoading { ProgressView() }
                        }
                    }
                    .disabled(identifyLoading)
                } else {
                    unavailableRow
                }
            }
        }

        // MARK: - Вспомогательные

        /// Ряд «недоступно» для секций требующих активного коннекта.
        private var unavailableRow: some View {
            Text("Недоступно — устройство не подключено")
                .foregroundStyle(.secondary)
                .font(.footnote)
        }

        /// Устройство — текущий активный коннект.
        private var isActiveDevice: Bool {
            pumpManager.activeBridgeUUID == device.id
        }

        // MARK: - Запросы

        /// Вызывается при появлении экрана: RSSI + прошивка + статистика.
        private func fetchOnOpen() {
            rssi = device.rssi
            pumpManager.bleManager.updateRSSI()
            if isActiveDevice {
                Task {
                    await fetchFirmware()
                    await fetchStats()
                }
            }
        }

        private func updateRSSI() {
            pumpManager.bleManager.updateRSSI()
            // Актуальный RSSI из discovered (обновился через BLE-цикл).
            let r = pumpManager.bleManager.discovered[device.id]?.rssi
            if let r, r != 0 { rssi = r }
        }

        private func fetchFirmware() async {
            firmwareLoading = true
            do {
                firmwareVersion = try await pumpManager.fetchPing()
            } catch {
                firmwareVersion = nil
                errorMessage = "PING: \(error.localizedDescription)"
            }
            firmwareLoading = false
        }

        private func fetchStats() async {
            statsLoading = true
            do {
                stats = try await pumpManager.fetchStatistics()
                errorMessage = nil
            } catch {
                errorMessage = "GET_STATISTICS: \(error.localizedDescription)"
            }
            statsLoading = false
        }

        private func identify() async {
            identifyLoading = true
            do {
                try await pumpManager.setBridgeLED(action: 2)
                errorMessage = nil
            } catch {
                errorMessage = "SET_LED: \(error.localizedDescription)"
            }
            identifyLoading = false
        }

        // MARK: - Утилиты

        /// Форматирует секунды uptime в читаемую строку: "2 дн 3 ч 15 мин" / "5 ч 12 мин" / "42 мин".
        private func formatUptime(_ seconds: UInt32) -> String {
            let totalMinutes = seconds / 60
            let days = totalMinutes / 1440
            let hours = (totalMinutes % 1440) / 60
            let minutes = totalMinutes % 60
            if days > 0 {
                return "\(days) дн \(hours) ч \(minutes) мин"
            } else if hours > 0 {
                return "\(hours) ч \(minutes) мин"
            } else {
                return "\(minutes) мин"
            }
        }
    }
#endif
