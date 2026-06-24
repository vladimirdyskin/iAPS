#if canImport(SwiftUI) && canImport(LoopKitUI)
    import LoopKit
    import PickleLinkKit
    import SwiftUI

    struct PickleLinkSettingsView: View {
        let pumpManager: PickleLinkPumpManager
        let onDelete: () -> Void

        @State private var stats: DeviceStatistics?
        @State private var diagnosticError: String?

        // Управление (тест): поля ввода и результат
        @State private var tempRate = "1.0"
        @State private var tempMins = "30"
        @State private var bolusUnits = "0.5"
        @State private var showBolusConfirm = false
        @State private var actionResult: String?
        @State private var busy = false

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

                Section(header: Text("Управление (тест)")) {
                    Button("Приостановить (suspend)") { runSuspend() }
                        .disabled(busy)
                    Button("Возобновить (resume)") { runResume() }
                        .disabled(busy)

                    HStack {
                        TextField("U/h", text: $tempRate)
                            .keyboardType(.decimalPad).frame(width: 60)
                        TextField("мин", text: $tempMins)
                            .keyboardType(.numberPad).frame(width: 60)
                        Spacer()
                        Button("Temp basal") { runTempBasal() }.disabled(busy)
                    }
                    Button("Отменить temp basal") { runTempCancel() }
                        .disabled(busy)

                    HStack {
                        TextField("U", text: $bolusUnits)
                            .keyboardType(.decimalPad).frame(width: 60)
                        Spacer()
                        Button("Болюс") { showBolusConfirm = true }
                            .disabled(busy).foregroundColor(.orange)
                    }

                    if busy { ProgressView() }
                    if let r = actionResult {
                        Text(r).font(.caption)
                            .foregroundColor(r.hasPrefix("OK") ? .green : .red)
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
            .alert("Болюс \(bolusUnits) U?", isPresented: $showBolusConfirm) {
                Button("Отмена", role: .cancel) {}
                Button("Болюс \(bolusUnits) U", role: .destructive) { runBolus() }
            } message: {
                Text("Реальная подача инсулина в помпу. Проверь дозу.")
            }
        }

        // MARK: - Действия (используют существующие методы PumpManager)

        private func finish(_ prefix: String, _ error: Error?) {
            DispatchQueue.main.async {
                busy = false
                actionResult = error == nil ? "OK: \(prefix)" : "\(prefix): \(error!)"
            }
        }

        private func runSuspend() {
            busy = true
            actionResult = nil
            pumpManager.suspendDelivery { finish("suspend", $0) }
        }

        private func runResume() {
            busy = true
            actionResult = nil
            pumpManager.resumeDelivery { finish("resume", $0) }
        }

        private func runTempBasal() {
            guard let rate = Double(tempRate), let mins = Double(tempMins), mins > 0 else {
                actionResult = "неверные числа temp basal"
                return
            }
            busy = true
            actionResult = nil
            pumpManager.enactTempBasal(unitsPerHour: rate, for: mins * 60) {
                finish("temp \(rate)U/h \(Int(mins))мин", $0)
            }
        }

        private func runTempCancel() {
            busy = true
            actionResult = nil
            pumpManager.enactTempBasal(unitsPerHour: 0, for: 0) { finish("temp cancel", $0) }
        }

        private func runBolus() {
            guard let u = Double(bolusUnits), u > 0 else {
                actionResult = "неверная доза"
                return
            }
            busy = true
            actionResult = nil
            pumpManager.enactBolus(units: u, activationType: .manualNoRecommendation) {
                finish("bolus \(u)U", $0)
            }
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
