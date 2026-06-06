// Requires linking against LoopKit/LoopKitUI/MinimedKit — built via iAPS Xcode project, not `swift build`.
#if canImport(SwiftUI) && canImport(LoopKitUI)
    import SwiftUI

    struct SetupCompleteView: View {
        @ObservedObject var model: PickleLinkSetupModel
        let onFinish: () -> Void

        var body: some View {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .resizable().frame(width: 64, height: 64).foregroundColor(.green)
                Text("PickleLink настроен").font(.title2)
                if let m = model.pumpModel {
                    Text("Модель помпы: \(m.rawValue)")
                }
                Text("Pump ID: \(model.lastPumpID)")
                if let v = model.firmwareVersion {
                    Text("Прошивка: \(v)").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Завершить", action: onFinish)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Готово")
        }
    }
#endif
