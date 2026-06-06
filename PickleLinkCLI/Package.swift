// swift-tools-version:5.9
import PackageDescription

// Standalone BLE test harness for PickleLink Smart Bridge firmware.
// Separate package (path-depends on PickleLinkKit) so it never touches
// PickleLinkKit/Package.swift while the PumpManager agent edits it.
let package = Package(
    name: "PickleLinkCLI",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../PickleLinkKit")
    ],
    targets: [
        .executableTarget(
            name: "PickleLinkCLI",
            dependencies: [
                .product(name: "PickleLinkKit", package: "PickleLinkKit")
            ],
            path: "Sources/PickleLinkCLI"
        )
    ]
)
