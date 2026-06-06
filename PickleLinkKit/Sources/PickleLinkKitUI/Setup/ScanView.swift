// Requires linking against LoopKit/LoopKitUI/MinimedKit — built via iAPS Xcode project, not `swift build`.
#if canImport(SwiftUI) && canImport(LoopKitUI)
    import SwiftUI

    struct ScanView: View {
        @ObservedObject var model: PickleLinkSetupModel

        var body: some View {
            List {
                Section(header: Text("Найденные устройства")) {
                    if model.devices.isEmpty {
                        HStack { ProgressView()
                            Text("Поиск PickleLink…") }
                    }
                    ForEach(model.devices, id: \.id) { dev in
                        Button {
                            model.connect(dev)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(dev.name ?? "PickleLink")
                                    Text(dev.id.uuidString).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("\(dev.rssi) dBm").foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Поиск устройства")
            .onAppear { model.startScan() }
            .onDisappear { model.stopScan() }
        }
    }
#endif
