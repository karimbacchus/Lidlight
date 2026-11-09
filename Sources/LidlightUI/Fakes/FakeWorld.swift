import AppKit
import LidlightKit

/// A complete set of fakes wired into an `AppModel`, for checks, snapshots and the demo.
package struct FakeWorld {
    package let scene: FakeLogoScene
    package let driver: FakeLogoDriver
    package let engine: FakeEngine
    package let system: FakeSystemMonitor
    package let agents: FakeAgentMonitor
    package let hooks: FakeHooksManager
    package let beats: FakeBeatSource
    package let login: FakeLoginItem
    package let defaults: UserDefaults
    package let model: AppModel

    /// - Parameter suiteName: UserDefaults suite; cleared on creation so every world starts fresh.
    package init(suiteName: String, simulated: Bool = true, audio: AudioCapturePermission = .granted) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        scene = FakeLogoScene()
        driver = FakeLogoDriver(scene: scene, isSimulated: simulated)
        engine = FakeEngine(scene: scene)
        system = FakeSystemMonitor()
        agents = FakeAgentMonitor()
        hooks = FakeHooksManager()
        beats = FakeBeatSource(permission: audio)
        login = FakeLoginItem()
        self.defaults = defaults
        model = AppModel(
            driver: driver, preview: driver, engine: engine, system: system, agents: agents,
            hooks: hooks, beats: beats, helperURL: URL(fileURLWithPath: "/Applications/Lidlight.app/Contents/Helpers/lidlightctl"),
            defaults: defaults, loginItem: login
        )
    }
}

/// `swift run UIChecks --demo`: the complete UI on fakes.
package enum UIDemo {
    package static func run() -> Never {
        let world = FakeWorld(suiteName: "app.lidlight.demo")
        world.agents.startDemoCycle()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppController(model: world.model)
        controller.start()
        world.model.setShowsPreviewWindow(true)
        withExtendedLifetime((world, controller)) { app.run() }
        exit(0)
    }
}
