#if canImport(SwiftUI) && canImport(LoopKitUI)
    import LoopKit
    import PickleLinkKit
    import SwiftUI

    struct PickleLinkSettingsView: View {
        let pumpManager: PickleLinkPumpManager
        let onDelete: () -> Void

        @State private var stats: DeviceStatistics?
        @State private var diagnosticError: String?

        var body: some View {
            Form {
                Section(header: Text("Помпа")) {
                    LabeledContent("Модель", value: pumpManager.state.pumpModel.rawValue)
                    LabeledContent("Pump ID", value: pumpManager.state.pumpID)
                    if let r = pumpManager.state.reservoirUnits {
                        LabeledContent("Резервуар", value: String(format: "%.1f U", r))
                    }
                }

                Section(header: Text("Радио")) {
                    if let f = pumpManager.state.frequencyHz {
                        LabeledContent("Частота", value: String(format: "%.3f MHz", Double(f) / 1_000_000))
                    } else {
                        Text("Частота: авто (mmtune)")
                    }
                    if let d = pumpManager.state.lastRadioErrorAt {
                        LabeledContent("Последняя radio-ошибка", value: d.formatted())
                    }
                    if let d = pumpManager.state.lastWatchdogAt {
                        LabeledContent("Последний watchdog", value: d.formatted())
                    }
                }

                Section(header: Text("Диагностика устройства")) {
                    if let s = stats {
                        LabeledContent("Батарея", value: "\(s.batteryMv) mV (\(s.batteryPct)%)")
                        LabeledContent("RX пакетов", value: "\(s.rxCount)")
                        LabeledContent("TX пакетов (8 бит)", value: "\(s.txCount)")
                    }
                    if let e = diagnosticError {
                        Text(e).foregroundColor(.red).font(.caption)
                    }
                    Button("Обновить (GET_STATISTICS)") {
                        Task { await refreshStats() }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Text("Удалить помпу")
                    }
                }
            }
            .navigationTitle("PickleLink")
        }

        private func refreshStats() async {
            do {
                stats = try await pumpManager.fetchStatistics() // 0x12
                diagnosticError = nil
            } catch {
                diagnosticError = "GET_STATISTICS: \(error)"
            }
        }
    }
#endif
