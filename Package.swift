// swift-tools-version: 6.0
//
// Lidlight — a menu bar app for the glowing lid logo on MacBook Pro with PROLED XDR Display.
//
// Module layout (one owner per module, see docs/PLAN.md):
//   LidlightKit          shared contracts: types, protocols, constants   (no dependencies)
//   CoreBrightnessBridge Objective-C shim over the private CoreBrightness framework
//   LidlightDriver       hardware driver, simulated driver, CLI commands, crash guardian
//   LidlightEngine       effect engine: Steady, Breathe, Battery, Music, Agents
//   LidlightSystem       display/lock/low-power/lid/battery/idle monitors
//   LidlightAgents       Claude Code hook events, session aggregation, hooks installer
//   LidlightAudio        system-audio tap + beat detection
//   LidlightUI           AppKit/SwiftUI menu bar UI, settings, preview window
//   LidlightApp          app composition root (executable)
//   lidlightctl          CLI composition root (executable, bundled in the app)
//   *Checks              per-module check executables (XCTest/Swift Testing are unavailable
//                        with Command Line Tools only), built on TestKit
//
// Build only what you own while others work in parallel, e.g.:
//   swift build --target LidlightEngine --scratch-path .build-engine
//   swift run   --scratch-path .build-engine EngineChecks

import PackageDescription

let package = Package(
    name: "Lidlight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LidlightApp", targets: ["LidlightApp"]),
        .executable(name: "lidlightctl", targets: ["lidlightctl"]),
    ],
    targets: [
        // MARK: Shared contracts
        .target(name: "LidlightKit"),

        // MARK: Hardware
        .target(
            name: "CoreBrightnessBridge",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .target(name: "LidlightDriver", dependencies: ["LidlightKit", "CoreBrightnessBridge"]),

        // MARK: Features
        .target(name: "LidlightEngine", dependencies: ["LidlightKit"]),
        .target(name: "LidlightSystem", dependencies: ["LidlightKit"]),
        .target(name: "LidlightAgents", dependencies: ["LidlightKit"]),
        .target(name: "LidlightAudio", dependencies: ["LidlightKit"]),
        .target(name: "LidlightUI", dependencies: ["LidlightKit"]),

        // MARK: Composition roots
        .executableTarget(
            name: "LidlightApp",
            dependencies: [
                "LidlightKit", "LidlightDriver", "LidlightEngine", "LidlightSystem",
                "LidlightAgents", "LidlightAudio", "LidlightUI",
            ]
        ),
        .executableTarget(
            name: "lidlightctl",
            dependencies: ["LidlightKit", "LidlightDriver", "LidlightAgents", "LidlightAudio"]
        ),

        // MARK: Checks (run with `swift run <Name>`)
        .target(name: "TestKit", path: "Checks/TestKit"),
        .executableTarget(name: "DriverChecks", dependencies: ["LidlightDriver", "TestKit"], path: "Checks/DriverChecks"),
        .executableTarget(name: "EngineChecks", dependencies: ["LidlightEngine", "TestKit"], path: "Checks/EngineChecks"),
        .executableTarget(name: "SystemChecks", dependencies: ["LidlightSystem", "TestKit"], path: "Checks/SystemChecks"),
        .executableTarget(name: "AgentsChecks", dependencies: ["LidlightAgents", "TestKit"], path: "Checks/AgentsChecks"),
        .executableTarget(name: "AudioChecks", dependencies: ["LidlightAudio", "TestKit"], path: "Checks/AudioChecks"),
        .executableTarget(name: "UIChecks", dependencies: ["LidlightUI", "TestKit"], path: "Checks/UIChecks"),
    ],
    swiftLanguageModes: [.v5]
)
