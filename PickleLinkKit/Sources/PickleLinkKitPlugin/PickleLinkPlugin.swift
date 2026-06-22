#if canImport(LoopKitUI)
    import LoopKitUI
    import os.log
    import PickleLinkKit
    import PickleLinkKitUI

    @objc(PickleLinkPlugin) final class PickleLinkPlugin: NSObject, PumpManagerUIPlugin {
        private let log = OSLog(subsystem: "com.pickle.PickleLinkKitPlugin", category: "Plugin")

        public var pumpManagerType: PumpManagerUI.Type? {
            PickleLinkPumpManager.self
        }

        public var cgmManagerType: CGMManagerUI.Type? { nil }

        override init() {
            super.init()
            os_log("PickleLinkPlugin instantiated", log: log, type: .default)
        }
    }
#endif
