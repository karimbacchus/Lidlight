// UI module checks. Run: swift run UIChecks
//   --demo              launch the complete UI on fakes
//   --snapshots <dir>   render popover/settings/preview PNGs (light and dark) into <dir>

import AppKit
import Foundation
import TestKit
import LidlightKit
@testable import LidlightUI

let arguments = CommandLine.arguments

if arguments.contains("--demo") {
    UIDemo.run()
}

if let flag = arguments.firstIndex(of: "--snapshots") {
    let directory = URL(fileURLWithPath: arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ".build-ui/snapshots")
    do {
        for url in try MainActor.assumeIsolated({ try UISnapshots.renderAll(into: directory) }) { print(url.path) }
    } catch {
        print("snapshot failed: \(error)")
        exit(1)
    }
    exit(0)
}

let t = TestRun("UI")

t.test("brightness curve matches the spec") {
    t.expectClose(BrightnessCurve.nits(forSlider: 0), 3, tolerance: 1e-9)
    t.expectClose(BrightnessCurve.nits(forSlider: 1), 1000, tolerance: 1e-9)
    t.expectClose(BrightnessCurve.nits(forSlider: 0.5), 3 + 997 * pow(0.5, 2.2), tolerance: 1e-6)
    t.expectClose(BrightnessCurve.slider(forNits: BrightnessCurve.nits(forSlider: 0.37)), 0.37, tolerance: 1e-9)
    t.expectEqual(BrightnessCurve.label(forSlider: 1), "1000 nits")
    t.expectEqual(BrightnessCurve.label(forSlider: 5), "1000 nits", "clamped")
}

t.test("breathe speed: right is fast, range 3...10 s") {
    t.expectEqual(BreatheSpeed.period(forSlider: 0), 10)
    t.expectEqual(BreatheSpeed.period(forSlider: 1), 3)
    t.expectEqual(BreatheSpeed.period(forSlider: BreatheSpeed.slider(forPeriod: 6)), 6)
    t.expectEqual(BreatheSpeed.label(forPeriod: 6), "6 s per breath")
    t.expectEqual(BreatheSpeed.label(forPeriod: 4.5), "4.5 s per breath")
    t.expectEqual(Percent.label(0.7), "70%")
}

t.test("readout, pause banners, agents and battery lines") {
    t.expectEqual(Texts.readout(state: LogoState(finalNits: 741.6), isOn: true), "Logo · 742 nits")
    t.expectEqual(Texts.readout(state: nil, isOn: true), "Logo · —")
    t.expectEqual(Texts.readout(state: LogoState(finalNits: 500), isOn: false), "Logo · Off")
    t.expectEqual(Texts.pauseBanner(.lowPowerMode), "Paused — Low Power Mode")
    t.expect(Texts.pauseBanner(.logoOff) == nil && Texts.pauseBanner(nil) == nil)
    let now = Date()
    t.expectEqual(Texts.agentsLine(AgentSnapshot()), "No Claude Code sessions")
    t.expectEqual(Texts.agentsLine(AgentSnapshot(activity: .working, sessions: 2, working: 1, needingYou: 0, updatedAt: now)),
                  "2 sessions · 1 working")
    t.expectEqual(Texts.agentsLine(AgentSnapshot(activity: .needsYou, sessions: 1, working: 0, needingYou: 1, updatedAt: now)),
                  "1 session · 1 needs you")
    var system = SystemStatus()
    t.expectEqual(Texts.batteryLine(system), "No battery in this Mac")
    system.batteryPercent = 82
    system.isCharging = true
    t.expectEqual(Texts.batteryLine(system), "Battery 82% · charging")
}

t.test("each mode shows its own controls") {
    t.expectEqual(LogoMode.steady.controls(audioPermission: .granted), [])
    t.expectEqual(LogoMode.breathe.controls(audioPermission: .granted), [.breatheSpeed])
    t.expectEqual(LogoMode.battery.controls(audioPermission: .granted), [.batteryCharge])
    t.expectEqual(LogoMode.agents.controls(audioPermission: .granted), [.agentsConnection, .agentsLive])
    t.expectEqual(LogoMode.music.controls(audioPermission: .granted), [.musicIntensity, .musicStrobe])
    t.expectEqual(LogoMode.music.controls(audioPermission: .denied), [.musicPermission, .musicIntensity, .musicStrobe])
}

t.test("menu bar icon state mapping") {
    t.expectEqual(MenuBarIconState(status: EngineStatus(isOn: false, mode: .breathe)), .off)
    t.expectEqual(MenuBarIconState(status: EngineStatus(isOn: true, mode: .steady)), .on)
    t.expectEqual(MenuBarIconState(status: EngineStatus(isOn: true, mode: .battery)), .on)
    t.expectEqual(MenuBarIconState(status: EngineStatus(isOn: true, mode: .music)), .animated)
    t.expectEqual(MenuBarIconState(status: EngineStatus(isOn: true, mode: .agents, pausedReason: .lowPowerMode)), .on)
    for state in [MenuBarIconState.on, .off, .animated] {
        let image = MenuBarIcon.image(for: state)
        t.expect(image.isTemplate && image.size == NSSize(width: 18, height: 18))
    }
}

t.test("quit flow asks only when the logo is off") {
    t.expectEqual(QuitFlow.decision(logoIsOn: true), .quit(keepOff: false))
    t.expectEqual(QuitFlow.decision(logoIsOn: false), .askKeepOff)
}

t.test("settings JSON round trip and defaults") {
    let world = FakeWorld(suiteName: "app.lidlight.checks.roundtrip")
    t.expectEqual(world.model.settings, AppSettings())
    world.model.start()
    world.model.setMode(.breathe)
    world.model.setBrightness(0.4)
    world.model.setBreathePeriod(8)
    world.model.setOn(false)
    let reloaded = AppModel.loadSettings(from: world.defaults)
    t.expectEqual(reloaded, world.model.settings)
    t.expectEqual(reloaded.mode, .breathe)
    t.expectEqual(reloaded.effects.breathePeriod, 8)
    t.expect(!reloaded.isOn)
    world.defaults.set(Data("not json".utf8), forKey: AppModel.settingsKey)
    t.expectEqual(AppModel.loadSettings(from: world.defaults), AppSettings(), "garbage falls back to defaults")
    var wild = AppSettings()
    wild.effects.breathePeriod = 99
    wild.effects.brightness = -3
    world.defaults.set(try JSONEncoder().encode(wild), forKey: AppModel.settingsKey)
    let clamped = AppModel.loadSettings(from: world.defaults).effects
    t.expectEqual(clamped.breathePeriod, 10)
    t.expectEqual(clamped.brightness, 0)
}

t.test("model start applies settings to every service") {
    let world = FakeWorld(suiteName: "app.lidlight.checks.start")
    var saved = AppSettings()
    saved.mode = .agents
    saved.isOn = false
    world.defaults.set(try JSONEncoder().encode(saved), forKey: AppModel.settingsKey)
    let restored = AppModel(
        driver: world.driver, preview: world.driver, engine: world.engine, system: world.system,
        agents: world.agents, hooks: world.hooks, beats: world.beats,
        helperURL: URL(fileURLWithPath: "/x/lidlightctl"), defaults: world.defaults, loginItem: world.login
    )
    restored.start()
    t.expect(world.engine.calls.contains("start(false,agents)"), "\(world.engine.calls)")
    t.expect(world.system.isRunning && world.agents.isRunning)
    t.expect(!world.beats.isRunning)
}

t.test("mode change starts and stops the beat source") {
    let world = FakeWorld(suiteName: "app.lidlight.checks.beats")
    world.model.start()
    t.expect(!world.beats.isRunning)
    world.model.setMode(.music)
    t.expect(world.beats.isRunning)
    t.expectEqual(world.beats.startCount, 1)
    world.model.setMode(.music)
    t.expectEqual(world.beats.startCount, 1, "no restart")
    world.model.setMode(.breathe)
    t.expect(!world.beats.isRunning)
    t.expectEqual(world.beats.stopCount, 1)
    t.expectEqual(world.model.engineStatus.mode, .breathe)
}

t.test("beat source failure surfaces the permission state") {
    let world = FakeWorld(suiteName: "app.lidlight.checks.denied", audio: .denied)
    world.beats.startError = LogoDriverError.notAllowed("denied")
    world.model.start()
    world.model.setMode(.music)
    t.expect(!world.beats.isRunning)
    t.expectEqual(world.model.audioPermission, .denied)
    world.beats.startError = nil
    world.beats.permission = .granted
    world.model.refreshAudioAccess()
    t.expect(world.beats.isRunning)
    t.expectEqual(world.model.audioPermission, .granted)
    world.model.setMode(.steady)
}

t.test("controls reach the engine and persist") {
    let world = FakeWorld(suiteName: "app.lidlight.checks.controls")
    world.model.start()
    world.model.setMusicStrobe(true)
    world.model.setFullBrightnessInAnyRoom(true)
    world.model.setAgentAwayAfter(45)
    t.expect(world.engine.settings.musicStrobe && world.engine.settings.fullBrightnessInAnyRoom)
    t.expectEqual(world.engine.settings.agentAwayAfter, 45)
    world.model.setOn(false)
    t.expect(world.engine.calls.contains("setOn(false)"))
    t.expectEqual(world.model.engineStatus.pausedReason, .logoOff)
    world.model.toggleOn()
    t.expect(world.model.settings.isOn)
    t.expectEqual(AppModel.loadSettings(from: world.defaults), world.model.settings)
    world.model.previewAgents(.needsYou)
    t.expect(world.engine.calls.contains("preview(needsYou)"))
}

t.test("system and agent updates reach the engine and the published state") {
    let world = FakeWorld(suiteName: "app.lidlight.checks.updates")
    world.model.start()
    world.model.setMode(.breathe)
    world.system.emit { $0.lowPowerMode = true }
    t.expect(world.model.systemStatus.lowPowerMode)
    t.expectEqual(world.model.engineStatus.pausedReason, .lowPowerMode)
    world.agents.emit(AgentSnapshot(activity: .working, sessions: 1, working: 1, needingYou: 0, updatedAt: Date()))
    t.expectEqual(world.model.agentSnapshot.sessions, 1)
    t.expectEqual(world.model.engineStatus.shownActivity, .working)
}

t.test("hooks connect and disconnect use the helper path") {
    let world = FakeWorld(suiteName: "app.lidlight.checks.hooks")
    world.model.start()
    world.model.connectAgents()
    t.expectEqual(world.hooks.connectedPaths, ["/Applications/Lidlight.app/Contents/Helpers/lidlightctl"])
    t.expectEqual(world.model.hooksStatus, .installed)
    t.expect(world.model.settings.agentsConnected)
    world.model.disconnectAgents()
    t.expectEqual(world.model.hooksStatus, .notInstalled)
    world.hooks.failure = LogoDriverError.notAllowed("read-only")
    world.model.connectAgents()
    t.expect(world.model.hooksError != nil)
    t.expect(!world.model.settings.agentsConnected)
}

t.test("login item failure shows an error and keeps the real state") {
    let world = FakeWorld(suiteName: "app.lidlight.checks.login")
    world.model.start()
    world.model.setOpenAtLogin(true)
    t.expect(world.model.settings.openAtLogin && world.model.loginItemError == nil)
    world.login.failure = LogoDriverError.unsupported
    world.model.setOpenAtLogin(false)
    t.expect(world.model.loginItemError != nil)
    t.expect(world.model.settings.openAtLogin, "unchanged because unregistering failed")
}

t.test("finishQuit restores defaults, stops services and honors keepOff") {
    let world = FakeWorld(suiteName: "app.lidlight.checks.quit")
    world.model.start()
    world.model.setOn(false)
    world.model.finishQuit(keepOff: true)
    t.expect(world.engine.lastShutdown?.restoreDefaults == true && world.engine.lastShutdown?.keepOff == true)
    t.expect(!world.model.settings.isOn)
    t.expect(!world.system.isRunning && !world.agents.isRunning)
    let other = FakeWorld(suiteName: "app.lidlight.checks.quit2")
    other.model.start()
    other.model.setOn(false)
    other.model.finishQuit(keepOff: false)
    t.expect(other.engine.lastShutdown?.keepOff == false)
    t.expect(other.model.settings.isOn, "Turn On is remembered for the next launch")
}

t.test("fake scene animates per mode") {
    let scene = FakeLogoScene()
    var effects = EffectSettings()
    effects.brightness = 1
    scene.update(effects: effects, paused: false)
    t.expectClose(scene.level(at: 0), 1, tolerance: 1e-9)
    scene.update(mode: .breathe)
    t.expect(scene.level(at: 0) < 0.1 && scene.level(at: 3) > 0.95)
    scene.update(mode: .music)
    t.expect(scene.level(at: 0.0) > scene.level(at: 0.4), "decays between beats")
    scene.update(isOn: false)
    t.expectEqual(scene.level(at: 1), 0)
}

t.finish()
