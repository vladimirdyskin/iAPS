// Requires linking against LoopKit/LoopKitUI/MinimedKit — built via iAPS Xcode project, not `swift build`.
#if canImport(SwiftUI) && canImport(LoopKitUI)
    import SwiftUI

    struct PumpIDEntryView: View {
        @ObservedObject var model: PickleLinkSetupModel
        @State private var pumpID: String = ""

        private var isValid: Bool { pumpID.count == 6 && pumpID.allSatisfy(\.isNumber) }

        var body: some View {
            Form {
                Section(footer: Text("6-значный номер на задней стороне помпы.")) {
                    TextField("123456", text: $pumpID)
                        .keyboardType(.numberPad)
                        .onChange(of: pumpID) { newValue in
                            pumpID = String(newValue.prefix(6).filter(\.isNumber))
                        }
                }
                if let e = model.errorMessage {
                    Text(e).foregroundColor(.red).font(.caption)
                }
                Section {
                    Button {
                        model.lastPumpID = pumpID
                        Task { await model.configure(pumpID: pumpID) }
                    } label: {
                        if model.busy { ProgressView() } else { Text("Применить") }
                    }
                    .disabled(!isValid || model.busy)
                }
            }
            .navigationTitle("ID помпы")
        }
    }
#endif
