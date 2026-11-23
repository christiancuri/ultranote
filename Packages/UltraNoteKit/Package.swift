// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "UltraNoteKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EditorBridge", targets: ["EditorBridge"]),
        .library(name: "EditorHost", targets: ["EditorHost"]),
        .library(name: "ExportKit", targets: ["ExportKit"]),
        .library(name: "NotesCore", targets: ["NotesCore"]),
    ],
    targets: [
        .target(name: "EditorBridge", swiftSettings: swiftSettings),
        .target(name: "EditorHost", dependencies: ["EditorBridge"], swiftSettings: swiftSettings),
        .target(name: "ExportKit", dependencies: ["EditorBridge", "EditorHost"], swiftSettings: swiftSettings),
        .target(name: "NotesCore", swiftSettings: swiftSettings),
        // A stand-in editor bundle that follows the bridge contract, shared by the test targets.
        .target(name: "EditorTestSupport", path: "Tests/EditorTestSupport", swiftSettings: swiftSettings),
        .testTarget(name: "EditorBridgeTests", dependencies: ["EditorBridge"], swiftSettings: swiftSettings),
        .testTarget(
            name: "EditorHostTests", dependencies: ["EditorBridge", "EditorHost", "EditorTestSupport"], swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ExportKitTests", dependencies: ["EditorBridge", "ExportKit", "EditorTestSupport"], swiftSettings: swiftSettings
        ),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"], swiftSettings: swiftSettings),
    ],
    swiftLanguageModes: [.v6]
)
