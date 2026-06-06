#if canImport(LoopKitUI) && canImport(UIKit)
    import LoopKit
    import LoopKitUI
    import PickleLinkKit
    import SwiftUI
    import UIKit

    extension PickleLinkPumpManager: PumpManagerUI {
        public static var onboardingImage: UIImage? { nil }

        public var smallImage: UIImage? { nil }

        public static func setupViewController(
            initialSettings settings: PumpManagerSetupSettings,
            bluetoothProvider _: BluetoothProvider,
            colorPalette: LoopUIColorPalette,
            allowDebugFeatures _: Bool,
            prefersToSkipUserInteraction _: Bool,
            allowedInsulinTypes: [InsulinType]
        ) -> SetupUIResult<PumpManagerViewController, PumpManagerUI> {
            let coordinator = PickleLinkUICoordinator(
                settings: settings,
                colorPalette: colorPalette,
                allowedInsulinTypes: allowedInsulinTypes
            )
            return .userInteractionRequired(coordinator)
        }

        public func settingsViewController(
            bluetoothProvider _: BluetoothProvider,
            colorPalette: LoopUIColorPalette,
            allowDebugFeatures _: Bool,
            allowedInsulinTypes: [InsulinType]
        ) -> PumpManagerViewController {
            PickleLinkUICoordinator(
                pumpManager: self,
                colorPalette: colorPalette,
                allowedInsulinTypes: allowedInsulinTypes
            )
        }

        public func deliveryUncertaintyRecoveryViewController(
            colorPalette: LoopUIColorPalette,
            allowDebugFeatures _: Bool
        ) -> (UIViewController & CompletionNotifying) {
            PickleLinkUICoordinator(
                pumpManager: self,
                colorPalette: colorPalette,
                allowedInsulinTypes: []
            )
        }

        public func hudProvider(
            bluetoothProvider _: BluetoothProvider,
            colorPalette _: LoopUIColorPalette,
            allowedInsulinTypes _: [InsulinType]
        ) -> HUDProvider? { nil }

        public static func createHUDView(rawValue _: HUDProvider.HUDViewRawState) -> BaseHUDView? { nil }
    }

    // MARK: - PumpStatusIndicator

    public extension PickleLinkPumpManager {
        var pumpStatusHighlight: DeviceStatusHighlight? { nil }
        var pumpLifecycleProgress: DeviceLifecycleProgress? { nil }
        var pumpStatusBadge: DeviceStatusBadge? { nil }
    }
#endif
