// Requires linking against LoopKit/LoopKitUI/MinimedKit — built via iAPS Xcode project, not `swift build`.
#if canImport(SwiftUI) && canImport(LoopKitUI)
    import SwiftUI

    struct FrequencyView: View {
        @ObservedObject var model: PickleLinkSetupModel
        @State private var mhz: String = "868.330"

        var body: some View {
            Form {
                Section(
                    footer: Text(
                        "Необязательно. По умолчанию устройство само подстраивает частоту (mmtune). Задавайте вручную только если знаете точное значение."
                    )
                ) {
                    TextField("868.330", text: $mhz).keyboardType(.decimalPad)
                }
                Section {
                    Button("Пропустить (рекомендуется)") {
                        Task { await model.setFrequency(hz: nil) }
                    }
                    Button("Задать частоту") {
                        if let m = Double(mhz) {
                            Task { await model.setFrequency(hz: UInt32(m * 1_000_000)) }
                        }
                    }
                }
            }
            .navigationTitle("Частота радио")
        }
    }
#endif
