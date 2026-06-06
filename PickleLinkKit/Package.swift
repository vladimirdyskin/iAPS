// swift-tools-version:5.9
import PackageDescription

// NOTE: PickleLinkKitUI + the PumpManager/UI/Plugin source files depend on
// LoopKit / LoopKitUI / MinimedKit, which are Xcode framework targets in the
// iAPS project and are NOT SwiftPM-consumable. Those files are wrapped in
// `#if canImport(LoopKit...)` so `swift build` / `swift test` keep working on
// the standalone BLE+Protocol core. To actually build the PumpManager and UI,
// the framework must be wired into the iAPS Xcode project (see report).

let package = Package(
    name: "PickleLinkKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PickleLinkKit",
            targets: ["PickleLinkKit"]
        ),
        .library(
            name: "PickleLinkKitUI",
            targets: ["PickleLinkKitUI"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PickleLinkKit",
            dependencies: [],
            path: "Sources/PickleLinkKit"
        ),
        .target(
            name: "PickleLinkKitUI",
            dependencies: ["PickleLinkKit"],
            path: "Sources/PickleLinkKitUI"
        ),
        .testTarget(
            name: "PickleLinkKitTests",
            dependencies: ["PickleLinkKit"],
            path: "Tests/PickleLinkKitTests"
        )
    ]
)
