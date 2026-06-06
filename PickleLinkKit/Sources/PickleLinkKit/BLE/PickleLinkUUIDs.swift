import Foundation
#if canImport(CoreBluetooth)
    import CoreBluetooth

    /// Static UUIDs for Smart Bridge BLE service.
    /// Spec: docs/smart_bridge_protocol.md §BLE Service
    public enum PickleLinkUUIDs {
        public static let service = CBUUID(string: "50494301-4C45-4000-8000-000000000001")
        public static let command = CBUUID(string: "50494301-4C45-4000-8000-000000000002")
        public static let response = CBUUID(string: "50494301-4C45-4000-8000-000000000003")
        public static let status = CBUUID(string: "50494301-4C45-4000-8000-000000000004")

        public static let advertisedDeviceName = "NRF"
        public static let firmwareIdentityString = "pickle_smart 1.0"
    }
#endif
