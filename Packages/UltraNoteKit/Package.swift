// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "UltraNoteKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "EditorBridge", targets: ["EditorBridge"]),
        .library(name: "EditorHost", targets: ["EditorHost"]),
        .library(name: "ExportKit", targets: ["ExportKit"]),
        .library(name: "NotesCore", targets: ["NotesCore"]),
    ],
    targets: [
        // Ask AI answers from the user's own installed Claude Code / Codex CLIs (child processes).
        .target(name: "AgentKit", swiftSettings: swiftSettings),
        .target(name: "EditorBridge", swiftSettings: swiftSettings),
        .target(name: "EditorHost", dependencies: ["EditorBridge"], swiftSettings: swiftSettings),
        .target(name: "ExportKit", dependencies: ["EditorBridge", "EditorHost"], swiftSettings: swiftSettings),
        .target(name: "NotesCore", swiftSettings: swiftSettings),
        // A stand-in editor bundle that follows the bridge contract, shared by the test targets.
        .target(name: "EditorTestSupport", path: "Tests/EditorTestSupport", swiftSettings: swiftSettings),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"], exclude: ["Fixtures"], swiftSettings: swiftSettings),
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
