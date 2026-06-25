#if canImport(SwiftUI) && canImport(LoopKitUI)
    import LoopKit
    import LoopKitUI
    import MinimedKit
    import PickleLinkKit
    import SwiftUI

    struct PickleLinkNativeSettingsView: View {
        @Environment(\.guidanceColors) private var guidanceColors
        @Environment(\.insulinTintColor) var insulinTintColor

        @ObservedObject var viewModel: PickleLinkSettingsViewModel
        @ObservedObject var listDataSource: PickleLinkListDataSource

        @State private var showingDeletionSheet = false

        // MARK: - Body

        var body: some View {
            List {
                // MARK: Header — графика + подача + резервуар

                Section {
                    headerImage
                        .padding(.vertical)
                    HStack(alignment: .top) {
                        deliveryStatus
                        Spacer()
                        reservoirStatus
                    }
                    .padding(.bottom, 5)
                }

                // MARK: Suspend / Resume

                if let basalDeliveryState = viewModel.basalDeliveryState {
                    Section {
                        HStack {
                            Button(basalDeliveryState.pickleButtonLabelText) {
                                viewModel.suspendResumeButtonPressed(action: basalDeliveryState.pickleShownAction)
                            }
                            .disabled(viewModel.suspendResumeButtonEnabled)
                            if viewModel.suspendResumeButtonEnabled {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                }

                // MARK: Устройства (мосты PickleLink)

                Section(header: HStack {
                    Text("Устройства")
                    Spacer()
                    ProgressView()
                }) {
                    ForEach(listDataSource.devices) { device in
                        // Паттерн RileyLink: имя → детальный экран, тоггл autoconnect справа.
                        // Toggle в Label не позволяет разделить нажатия, поэтому строим вручную.
                        HStack {
                            // Левая часть: NavigationLink → PickleLinkDeviceDetailView.
                            NavigationLink(destination: PickleLinkDeviceDetailView(
                                device: device,
                                pumpManager: viewModel.pumpManager
                            )) {
                                HStack {
                                    Text(device.name)
                                    Spacer()
                                    if listDataSource.autoconnectBinding(for: device.id).wrappedValue {
                                        if let rssi = device.rssi {
                                            Text(formatRSSI(rssi: rssi))
                                                .foregroundColor(device.isConnected ? .primary : .secondary)
                                        } else {
                                            Image(systemName: "wifi.exclamationmark")
                                                .imageScale(.large)
                                                .foregroundColor(guidanceColors.warning)
                                        }
                                    }
                                }
                            }
                            // Правая часть: тоггл autoconnect. Фиксированная ширина = нет «кражи» тапа.
                            Toggle("", isOn: listDataSource.autoconnectBinding(for: device.id))
                                .labelsHidden()
                                .fixedSize()
                        }
                    }
                }
                .onAppear { listDataSource.isScanningEnabled = true }
                .onDisappear { listDataSource.isScanningEnabled = false }

                // MARK: Status

                Section(header: Text("Статус")) {
                    HStack {
                        Text("Заряд батареи помпы")
                        Spacer()
                        if let charge = viewModel.pumpManager.status.pumpBatteryChargeRemaining {
                            Text("\(Int(round(charge * 100)))%")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("неизвестно")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Время помпы")
                        Spacer()
                        if viewModel.isClockOffset {
                            Image(systemName: "clock.fill")
                                .foregroundColor(guidanceColors.warning)
                        }
                        PickleLinkTimeView(timeZone: viewModel.pumpManager.status.timeZone)
                            .foregroundColor(viewModel.isClockOffset ? guidanceColors.warning : .secondary)
                    }
                }

                // MARK: Детали

                Section(header: Text("Детали")) {
                    LabeledValueView(
                        label: "Pump ID",
                        value: viewModel.pumpManager.state.pumpID
                    )
                    LabeledValueView(
                        label: "Модель",
                        value: viewModel.pumpManager.state.pumpModel.rawValue
                    )
                    if let hz = viewModel.pumpManager.state.frequencyHz {
                        LabeledValueView(
                            label: "Частота",
                            value: String(format: "%.3f MHz", Double(hz) / 1_000_000)
                        )
                    }
                }

                // MARK: Удалить помпу

                Section {
                    deletePumpButton
                }
            }
            .alert(item: $viewModel.activeAlert) { alert in
                switch alert {
                case let .suspendError(error):
                    return Alert(
                        title: Text("Ошибка приостановки"),
                        message: Text(errorText(error))
                    )
                case let .resumeError(error):
                    return Alert(
                        title: Text("Ошибка возобновления"),
                        message: Text(errorText(error))
                    )
                }
            }
            .insetGroupedListStyle()
            .navigationBarItems(trailing: doneButton)
            .navigationTitle("PickleLink")
        }

        // MARK: - Header image

        private var headerImage: some View {
            VStack(alignment: .center) {
                Image(uiImage: viewModel.pumpImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 100)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity)
        }

        // MARK: - Delivery status

        private var deliverySectionTitle: String {
            if viewModel.isScheduledBasal {
                return "Плановый базал"
            } else {
                return "Подача инсулина"
            }
        }

        private var deliveryStatus: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(deliverySectionTitle)
                    .foregroundColor(Color(UIColor.secondaryLabel))
                if viewModel.isSuspendedOrResuming {
                    HStack(alignment: .center) {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 34))
                            .fixedSize()
                            .foregroundColor(
                                viewModel.suspendResumeButtonColor(guidanceColors: guidanceColors)
                            )
                        Text("Инсулин\nприостановлен")
                            .fontWeight(.bold)
                            .fixedSize()
                    }
                } else if let rate = viewModel.basalDeliveryRate {
                    HStack(alignment: .center) {
                        HStack(alignment: .lastTextBaseline, spacing: 3) {
                            Text(viewModel.basalRateFormatter.string(from: NSNumber(value: rate)) ?? "")
                                .font(.system(size: 28))
                                .fontWeight(.heavy)
                                .fixedSize()
                            Text("U/hr")
                                .foregroundColor(.secondary)
                        }
                    }
                } else if viewModel.basalDeliveryState?.pickleIsTransitioning == true {
                    HStack(alignment: .center) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 34))
                            .fixedSize()
                            .foregroundColor(.secondary)
                        Text("Изменение...")
                            .fontWeight(.bold)
                            .fixedSize()
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack(alignment: .center) {
                        Image(systemName: "x.circle.fill")
                            .font(.system(size: 34))
                            .fixedSize()
                            .foregroundColor(guidanceColors.warning)
                        Text("Неизвестно")
                            .fontWeight(.bold)
                            .fixedSize()
                    }
                }
            }
        }

        // MARK: - Reservoir status

        private func reservoirColor(for state: PickleLinkReservoirHighlightState) -> Color {
            switch state {
            case .normal: return insulinTintColor
            case .warning: return guidanceColors.warning
            case .critical: return guidanceColors.critical
            }
        }

        private var reservoirStatus: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text("Осталось инсулина")
                    .foregroundColor(Color(UIColor.secondaryLabel))
                if let units = viewModel.reservoirUnits,
                   let highlight = viewModel.reservoirLevelHighlightState,
                   let pct = viewModel.reservoirPercentage
                {
                    HStack {
                        PickleLinkReservoirView(
                            filledPercent: pct,
                            fillColor: reservoirColor(for: highlight)
                        )
                        .frame(width: 23, height: 32)
                        Text(viewModel.reservoirText(for: units))
                            .font(.system(size: 28))
                            .fontWeight(.heavy)
                            .fixedSize()
                    }
                }
            }
        }

        // MARK: - Helpers

        private func errorText(_ error: Error) -> String {
            if let e = error as? LocalizedError {
                return [e.localizedDescription, e.recoverySuggestion].compactMap { $0 }.joined(separator: ". ")
            }
            return error.localizedDescription
        }

        private func formatRSSI(rssi: Int?) -> String {
            guard let rssi else { return "" }
            return "\(rssi) dB"
        }

        private var deletePumpButton: some View {
            Button(action: { showingDeletionSheet = true }) {
                Text("Удалить помпу")
                    .foregroundColor(.red)
            }
            .actionSheet(isPresented: $showingDeletionSheet) {
                ActionSheet(
                    title: Text("Удалить эту помпу?"),
                    buttons: [
                        .destructive(Text("Удалить помпу")) { viewModel.deletePump() },
                        .cancel()
                    ]
                )
            }
        }

        private var doneButton: some View {
            Button("Готово") { viewModel.doneButtonPressed() }
        }
    }

    // MARK: - Индикатор резервуара (скопирован из MinimedReservoirView, ассеты из MinimedKitUI bundle)

    private struct PickleLinkReservoirView: View {
        let filledPercent: Double
        let fillColor: Color

        private let maskHeightRatio = 0.887
        private let reservoirAspectRatio = 28.0 / 44.0

        // Bundle MinimedKitUI — там лежат изображения reservoir / reservoir_mask
        private let bundle = Bundle(identifier: "org.loopkit.MinimedKitUI") ?? Bundle.main

        private func reservoirSize(in frame: CGSize) -> CGSize {
            let frameAR = frame.width / frame.height
            if frameAR > reservoirAspectRatio {
                return CGSize(width: frame.height * reservoirAspectRatio, height: frame.height)
            } else {
                return CGSize(width: frame.width, height: frame.width / reservoirAspectRatio)
            }
        }

        var body: some View {
            ZStack(alignment: Alignment(horizontal: .center, vertical: .center)) {
                GeometryReader { geometry in
                    let size = reservoirSize(in: geometry.size)
                    let cx = geometry.size.width / 2
                    let cy = geometry.size.height / 2
                    let maskH = size.height * maskHeightRatio
                    let fillH = maskH * filledPercent
                    let maskOff = (size.height - maskH) / 2

                    if let maskImg = UIImage(named: "reservoir_mask", in: bundle, compatibleWith: nil) {
                        Rectangle()
                            .fill(fillColor)
                            .mask(
                                Image(uiImage: maskImg)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: maskH)
                                    .position(x: cx, y: cy + maskOff)
                            )
                            .mask(
                                Rectangle().path(in: CGRect(
                                    x: 0,
                                    y: cy + maskH / 2 - fillH + maskOff,
                                    width: geometry.size.width,
                                    height: fillH
                                ))
                            )
                    }
                }
                if let img = UIImage(named: "reservoir", in: bundle, compatibleWith: nil) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                }
            }
        }
    }

    // MARK: - Вспомогательный Time View

    private struct PickleLinkTimeView: View {
        let timeZone: TimeZone

        private let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return f
        }()

        @State private var currentDate = Date()
        private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

        var body: some View {
            Text(formattedTime)
                .onReceive(timer) { currentDate = $0 }
        }

        private var formattedTime: String {
            formatter.timeZone = timeZone
            return formatter.string(from: currentDate)
        }
    }
#endif
