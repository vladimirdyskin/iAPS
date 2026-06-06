// Requires linking against LoopKit/LoopKitUI/MinimedKit — built via iAPS Xcode project, not `swift build`.
#if canImport(SwiftUI) && canImport(LoopKitUI)
    import SwiftUI

    struct PairingView: View {
        @ObservedObject var model: PickleLinkSetupModel

        var body: some View {
            VStack(spacing: 16) {
                ProgressView()
                Text("Подключение и проверка прошивки…")
                if let v = model.firmwareVersion {
                    Text("Прошивка: \(v)").font(.caption)
                }
                if let e = model.errorMessage {
                    Text(e).foregroundColor(.red).font(.caption)
                    Button("Назад к поиску") { model.errorMessage = nil
                        model.startScan() }
                }
            }
            .padding()
            .navigationTitle("Сопряжение")
        }
    }
#endif
