#if canImport(LoopKitUI) && canImport(UIKit)
    import Combine
    import LoopKit
    import LoopKitUI
    // MinimedKit не импортируется: PumpModel in-module PickleLinkKit (Medtronic/)
    import PickleLinkKit
    import SwiftUI
    import UIKit

    final class PickleLinkUICoordinator: UINavigationController, PumpManagerOnboarding, CompletionNotifying {
        weak var pumpManagerOnboardingDelegate: PumpManagerOnboardingDelegate?
        weak var completionDelegate: CompletionDelegate?

        private let model = PickleLinkSetupModel()
        private let colorPalette: LoopUIColorPalette
        private var existingPumpManager: PickleLinkPumpManager?

        init(
            pumpManager: PickleLinkPumpManager? = nil,
            settings: PumpManagerSetupSettings? = nil,
            colorPalette: LoopUIColorPalette,
            allowedInsulinTypes: [InsulinType]
        )
        {
            self.colorPalette = colorPalette
            existingPumpManager = pumpManager
            super.init(nibName: nil, bundle: nil)
            if let s = settings {
                model.maxBasalRateUnitsPerHour = s.maxBasalRateUnitsPerHour
                model.maxBolusUnits = s.maxBolusUnits
                model.basalSchedule = s.basalSchedule
            }
            if let it = allowedInsulinTypes.first { model.insulinType = it }
            observePhase()
        }

        @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            if let pm = existingPumpManager {
                let vm = PickleLinkSettingsViewModel(pumpManager: pm)
                vm.didFinish = { [weak self] in self?.finish() }
                let dataSource = PickleLinkListDataSource(pumpManager: pm)
                let view = PickleLinkNativeSettingsView(viewModel: vm, listDataSource: dataSource)
                push(UIHostingController(rootView: view))
            } else {
                push(UIHostingController(rootView: ScanView(model: model)))
            }
        }

        private var lastPhase: PickleLinkSetupModel.Phase?

        private func observePhase() {
            // Lightweight polling-free: re-render on each navigation by reacting in
            // navigationController updates. Phase changes are pushed from views via model.
            // Use a Combine sink.
            phaseCancellable = model.$phase.sink { [weak self] phase in
                DispatchQueue.main.async { self?.handle(phase) }
            }
        }

        private var phaseCancellable: AnyCancellable?

        private func handle(_ phase: PickleLinkSetupModel.Phase) {
            guard phase != lastPhase else { return }
            lastPhase = phase
            switch phase {
            case .scanning:
                break
            case .pairing:
                push(UIHostingController(rootView: PairingView(model: model)))
            case .pumpID:
                push(UIHostingController(rootView: PumpIDEntryView(model: model)))
            case .frequency:
                push(UIHostingController(rootView: FrequencyView(model: model)))
            case .complete:
                push(UIHostingController(rootView: SetupCompleteView(model: model) { [weak self] in
                    self?.finishOnboarding()
                }))
            }
        }

        private func push(_ vc: UIViewController) {
            pushViewController(vc, animated: !viewControllers.isEmpty)
        }

        private func finishOnboarding() {
            guard let state = model.makeState() else { finish()
                return }
            let pm = PickleLinkPumpManager(state: state)
            pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didCreatePumpManager: pm)
            pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didOnboardPumpManager: pm)
            finish()
        }

        private func finish() {
            completionDelegate?.completionNotifyingDidComplete(self)
        }
    }
#endif
