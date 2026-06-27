#if canImport(SwiftUI) && canImport(LoopKitUI) && canImport(UIKit)
    import Foundation
    import HealthKit
    import LoopKit
    import LoopKitUI
    // MinimedKit не импортируется: PumpModel in-module PickleLinkKit (Medtronic/)
    import PickleLinkKit
    import SwiftUI
    import UIKit

    // MARK: - Локальные enum (воспроизводят аналоги из MinimedKitUI)

    enum PickleLinkSuspendResumeAction {
        case suspend
        case resume
    }

    enum PickleLinkReservoirHighlightState {
        case normal
        case warning
        case critical
    }

    // MARK: - Alert enum

    enum PickleLinkSettingsViewAlert: Identifiable {
        case suspendError(Error)
        case resumeError(Error)
        case syncTimeError(Error)

        var id: String {
            switch self {
            case .suspendError: return "suspendError"
            case .resumeError: return "resumeError"
            case .syncTimeError: return "syncTimeError"
            }
        }
    }

    // MARK: - ViewModel

    final class PickleLinkSettingsViewModel: ObservableObject {
        // MARK: Published

        @Published var basalDeliveryState: PumpManagerStatus.BasalDeliveryState?
        @Published var reservoirUnits: Double?
        @Published var suspendResumeButtonEnabled: Bool = false
        @Published var synchronizingTime: Bool = false
        @Published var activeAlert: PickleLinkSettingsViewAlert?

        /// Возраст инсулина (смена резервуара), форматированный «N д M ч». Зеркало MinimedPumpSettingsViewModel.
        @Published var timeSinceLastRewind: String?

        /// Возраст набора (смена инфузионного сета), форматированный «N д M ч». Зеркало MinimedPumpSettingsViewModel.
        @Published var timeSinceLastSetChange: String?

        // MARK: Formatters

        let basalRateFormatter: NumberFormatter = {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.minimumFractionDigits = 1
            f.minimumIntegerDigits = 1
            return f
        }()

        let reservoirVolumeFormatter = {
            let f = QuantityFormatter(for: .internationalUnit())
            f.numberFormatter.maximumFractionDigits = 1
            return f
        }()

        // MARK: Manager

        let pumpManager: PickleLinkPumpManager
        var didFinish: (() -> Void)?

        // MARK: Init

        init(pumpManager: PickleLinkPumpManager) {
            self.pumpManager = pumpManager
            basalDeliveryState = pumpManager.status.basalDeliveryState
            reservoirUnits = pumpManager.state.reservoirUnits
            if let d = pumpManager.state.lastRewindDate { timeSinceLastRewind = formatDateToDaysHours(d) }
            if let d = pumpManager.state.lastSetChangeDate { timeSinceLastSetChange = formatDateToDaysHours(d) }
            pumpManager.addStatusObserver(self, queue: .main)
            pumpManager.addStateObserver(self, queue: .main)
        }

        // MARK: - Изображение помпы

        /// 7xx / 5xx Outline из bundle MinimedKitUI (ассеты доступны т.к. MinimedKit линкован в PickleLinkKitUI)
        var pumpImage: UIImage {
            let isLarger = pumpManager.state.pumpModel.reservoirCapacity > 200
            let name = isLarger ? "7xx Outline" : "5xx Outline"
            // Bundle по известному классу MinimedKitUI
            if let img = UIImage(named: name, in: bundleForMinimedKitUI, compatibleWith: nil) {
                return img
            }
            return UIImage(systemName: "cross.fill") ?? UIImage()
        }

        // Bundle MinimedKitUI — по идентификатору (в runtime оба framework загружены)
        private var bundleForMinimedKitUI: Bundle {
            Bundle(identifier: "org.loopkit.MinimedKitUI") ?? Bundle.main
        }

        // MARK: - Состояние доставки

        var isScheduledBasal: Bool {
            switch basalDeliveryState {
            case .active,
                 .initiatingTempBasal: return true
            default: return false
            }
        }

        var isSuspendedOrResuming: Bool {
            switch basalDeliveryState {
            case .resuming,
                 .suspended: return true
            default: return false
            }
        }

        var basalDeliveryRate: Double? {
            switch basalDeliveryState {
            case let .tempBasal(dose): return dose.unitsPerHour
            case .active,
                 .initiatingTempBasal:
                // Плановый базал: берём текущую скорость из расписания по времени суток.
                return pumpManager.state.basalSchedule?.value(at: Date())
            default: return nil
            }
        }

        func suspendResumeButtonColor(guidanceColors: GuidanceColors) -> Color {
            switch basalDeliveryState {
            case .resuming,
                 .suspending: return .secondary
            case .suspended: return guidanceColors.warning
            default: return .accentColor
            }
        }

        // MARK: - Резервуар

        var reservoirPercentage: Double? {
            guard let u = reservoirUnits else { return nil }
            let raw = u / pumpManager.pumpReservoirCapacity
            return max(0.0, min(1.0, raw))
        }

        var reservoirLevelHighlightState: PickleLinkReservoirHighlightState? {
            guard let u = reservoirUnits else { return nil }
            if u > 50 { return .normal }
            else if u > 0 { return .warning }
            else { return .critical }
        }

        func reservoirText(for units: Double) -> String {
            let q = HKQuantity(unit: .internationalUnit(), doubleValue: units)
            return reservoirVolumeFormatter.string(from: q) ?? ""
        }

        // MARK: - Батарея / время

        var isClockOffset: Bool {
            // currentFixed = TimeZone(secondsFromGMT: current.secondsFromGMT())
            let currentFixed = TimeZone(secondsFromGMT: TimeZone.current.secondsFromGMT()) ?? TimeZone.current
            return pumpManager.status.timeZone != currentFixed
        }

        // MARK: - Suspend / Resume (медицинский код — вызывает существующие методы PumpManager)

        func suspendResumeButtonPressed(action: PickleLinkSuspendResumeAction) {
            suspendResumeButtonEnabled = true
            switch action {
            case .resume:
                pumpManager.resumeDelivery { [weak self] error in
                    DispatchQueue.main.async {
                        self?.suspendResumeButtonEnabled = false
                        if let error { self?.activeAlert = .resumeError(error) }
                    }
                }
            case .suspend:
                pumpManager.suspendDelivery { [weak self] error in
                    DispatchQueue.main.async {
                        self?.suspendResumeButtonEnabled = false
                        if let error { self?.activeAlert = .suspendError(error) }
                    }
                }
            }
        }

        // MARK: - Синхронизация времени (зеркало MinimedPumpSettingsViewModel.changeTimeZoneTapped)

        func syncPumpTimeButtonPressed() {
            synchronizingTime = true
            pumpManager.syncPumpTime { [weak self] error in
                DispatchQueue.main.async {
                    self?.synchronizingTime = false
                    if let error { self?.activeAlert = .syncTimeError(error) }
                }
            }
        }

        // MARK: - Тип инсулина (зеркало MinimedPumpSettingsViewModel.didChangeInsulinType)

        func didChangeInsulinType(_ newType: InsulinType?) {
            pumpManager.insulinType = newType
        }

        // MARK: - Прочее

        func doneButtonPressed() { didFinish?() }

        func deletePump() {
            pumpManager.prepareForDeactivation { [weak self] _ in
                DispatchQueue.main.async { self?.didFinish?() }
            }
        }
    }

    // MARK: - Status observer

    extension PickleLinkSettingsViewModel: PumpManagerStatusObserver {
        func pumpManager(_: PumpManager, didUpdate status: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
            basalDeliveryState = status.basalDeliveryState
        }
    }

    // MARK: - State observer

    extension PickleLinkSettingsViewModel: PickleLinkPumpManagerStateObserver {
        func didUpdatePumpManagerState(_ state: PickleLinkPumpManagerState) {
            reservoirUnits = state.reservoirUnits
            if let d = state.lastRewindDate { timeSinceLastRewind = formatDateToDaysHours(d) }
            if let d = state.lastSetChangeDate { timeSinceLastSetChange = formatDateToDaysHours(d) }
        }
    }

    // MARK: - Форматирование дат (зеркало MinimedPumpSettingsViewModel.formatDateToDaysHours)

    private func formatDateToDaysHours(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.day, .hour], from: date, to: Date())
        let days = components.day ?? 0
        let hours = components.hour ?? 0
        let dayStr = days == 1 ? "д" : "д"
        let hourStr = hours == 1 ? "ч" : "ч"
        return "\(days) \(dayStr) \(hours) \(hourStr)"
    }

    // MARK: - BasalDeliveryState helpers (локальные, аналог extension в MinimedPumpSettingsViewModel)

    extension PumpManagerStatus.BasalDeliveryState {
        var pickleShownAction: PickleLinkSuspendResumeAction {
            switch self {
            case .active,
                 .cancelingTempBasal,
                 .initiatingTempBasal,
                 .suspending,
                 .tempBasal:
                return .suspend
            case .resuming,
                 .suspended:
                return .resume
            }
        }

        var pickleButtonLabelText: String {
            switch self {
            case .active,
                 .tempBasal:
                return "Приостановить подачу"
            case .suspending:
                return "Приостановка..."
            case .suspended:
                return "Возобновить подачу"
            case .resuming:
                return "Возобновление..."
            case .initiatingTempBasal:
                return "Запуск Temp Basal..."
            case .cancelingTempBasal:
                return "Отмена Temp Basal..."
            }
        }

        var pickleIsTransitioning: Bool {
            switch self {
            case .cancelingTempBasal,
                 .initiatingTempBasal,
                 .resuming,
                 .suspending: return true
            default: return false
            }
        }
    }
#endif
