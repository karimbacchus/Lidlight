// Engine module checks. Run: swift run --scratch-path .build-engine EngineChecks
// Patterns run on a virtual clock against a recording driver; one test uses the real timer.

import Foundation
import TestKit
import LidlightKit
import LidlightEngine

let t = TestRun("Engine")

func isFactor(_ call: Call) -> Bool {
    switch call {
    case .target, .fade: return true
    default: return false
    }
}

func tableWrites(_ rig: Rig) -> [(time: TimeInterval, call: Call)] {
    rig.calls { if case .tables = $0 { return true } else { return false } }
}

func tables(_ call: Call) -> LogoTables? {
    if case .tables(let t) = call { return t }
    return nil
}

func lastTables(_ rig: Rig) -> LogoTables? {
    tableWrites(rig).last.flatMap { tables($0.call) }
}

func releases(_ rig: Rig) -> Int {
    rig.calls { $0 == .release }.count
}

func alternates(_ writes: [Write]) -> Bool {
    zip(writes, writes.dropFirst()).allSatisfy { $0.target != $1.target }
}

/// Lit writes that follow a dark phase shorter than 0.5 s, by their times.
func flashTimes(_ writes: [Write]) -> [TimeInterval] {
    var darkSince: TimeInterval?
    var result: [TimeInterval] = []
    for w in writes {
        if w.target == .dark {
            darkSince = w.time
        } else if let since = darkSince {
            if w.time - since < 0.5 { result.append(w.time) }
            darkSince = nil
        }
    }
    return result
}

func maxFlashesPerSecond(_ times: [TimeInterval]) -> Int {
    times.map { start in times.filter { $0 >= start && $0 < start + 1 }.count }.max() ?? 0
}

// MARK: - Levels

t.test("slider to nits curve endpoints and shape") {
    t.expectClose(EffectEngine.nits(forBrightness: 0), 3, tolerance: 1e-9)
    t.expectClose(EffectEngine.nits(forBrightness: 1), 1000, tolerance: 1e-9)
    t.expectClose(EffectEngine.nits(forBrightness: 0.5), 3 + 997 * pow(0.5, 2.2), tolerance: 1e-9)
    t.expectClose(EffectEngine.nits(forBrightness: -1), 3, tolerance: 1e-9)
    t.expectClose(EffectEngine.nits(forBrightness: 2), 1000, tolerance: 1e-9)
    var last = 0.0
    for i in 0...20 {
        let n = EffectEngine.nits(forBrightness: Double(i) / 20)
        t.expect(n >= last)
        last = n
    }
}

// MARK: - Steady and tables

t.test("steady writes flat tables immediately and never touches the factor") {
    let rig = Rig()
    rig.start(.steady) { $0.brightness = 0.5 }
    rig.advance(5)
    let level = EffectEngine.nits(forBrightness: 0.5)
    let written = tableWrites(rig)
    t.expectEqual(written.count, 1)
    let tables = lastTables(rig)
    t.expectEqual(tables?.mapping, .flat(level))
    t.expectEqual(tables?.minRestriction, .flat(0))
    t.expectEqual(tables?.maxRestriction, LogoTables.appleDefaults.maxRestriction)
    t.expectEqual(rig.calls(isFactor).count, 0)
    t.expectEqual(rig.status.targetNits, level)
    t.expect(!rig.status.isAnimating)
    t.expectEqual(rig.status.pausedReason, nil)
}

t.test("full brightness in any room lifts the max restriction") {
    let rig = Rig()
    rig.start(.steady) { $0.fullBrightnessInAnyRoom = true }
    rig.advance(1)
    t.expectEqual(lastTables(rig)?.maxRestriction, .flat(1000))
}

t.test("level changes are debounced 300 ms and spaced 2 s apart") {
    let rig = Rig()
    rig.start(.steady)
    rig.advance(3)
    var s = EffectSettings()
    s.brightness = 0.3
    rig.core.setSettings(s)
    rig.advance(0.2)
    s.brightness = 0.31
    rig.core.setSettings(s)
    rig.advance(0.2)
    t.expectEqual(tableWrites(rig).count, 1, "still debouncing")
    rig.advance(0.2)
    t.expectEqual(tableWrites(rig).count, 2)
    t.expectEqual(lastTables(rig)?.mapping, .flat(EffectEngine.nits(forBrightness: 0.31)))
    // A change right after a write waits for the 2 s spacing.
    s.brightness = 0.6
    rig.core.setSettings(s)
    rig.advance(1)
    t.expectEqual(tableWrites(rig).count, 2)
    rig.advance(1.5)
    let times = tableWrites(rig).map(\.time)
    t.expectEqual(times.count, 3)
    t.expect(times[2] - times[1] >= 2 - 1e-6, "writes \(times)")
}

t.test("unchanged settings write no tables; reverting before the write cancels it") {
    let rig = Rig()
    rig.start(.steady)
    rig.advance(3)
    rig.core.setSettings(EffectSettings())
    rig.advance(3)
    t.expectEqual(tableWrites(rig).count, 1)
    var s = EffectSettings()
    s.brightness = 0.2
    rig.core.setSettings(s)
    rig.advance(0.1)
    rig.core.setSettings(EffectSettings())
    rig.advance(3)
    t.expectEqual(tableWrites(rig).count, 1)
}

// MARK: - Breathe

t.test("breathe: strict alternation, exact half-period spacing, levels and smoothness") {
    let rig = Rig()
    rig.start(.breathe) { $0.breathePeriod = 6 }
    rig.advance(60)
    let writes = rig.factorWrites
    t.expect(writes.count >= 19 && writes.count <= 21, "count \(writes.count)")
    t.expectEqual(writes.first?.target, .dark)
    t.expect(alternates(writes), "targets must alternate")
    for (a, b) in zip(writes, writes.dropFirst()) {
        t.expectClose(b.time - a.time, 3, tolerance: 1e-6)
    }
    // Fade duration is only written when it changes.
    let fadeWrites = rig.calls { if case .fade = $0 { return true } else { return false } }.count
    t.expect(fadeWrites <= 3, "fade writes \(fadeWrites)")
    let trace = FactorTrace(writes: writes)
    for w in writes.dropFirst() {
        let f = trace.factor(at: w.time)
        if w.target == .lit { t.expectClose(f, 0.04, tolerance: 0.005, "trough at \(w.time)") }
        else { t.expectClose(f, 0.96, tolerance: 0.005, "peak at \(w.time)") }
    }
    // Never flat: in any window of 10 % of a period the factor moves noticeably.
    let samples = trace.samples(from: 6, to: 54)
    let window = Int(0.6 / 0.005)
    var worst = 1.0
    for i in stride(from: 0, to: samples.count - window, by: 4) {
        let slice = samples[i...(i + window)]
        worst = min(worst, slice.max()! - slice.min()!)
    }
    t.expect(worst > 0.02, "flattest 10% window moves only \(worst)")
    t.expect(rig.status.isAnimating)
}

t.test("breathe speed change takes effect without restarting the pulse") {
    let rig = Rig()
    rig.start(.breathe) { $0.breathePeriod = 6 }
    rig.advance(4)
    let before = rig.factorWrites
    var s = EffectSettings()
    s.breathePeriod = 10
    rig.core.setSettings(s)
    rig.advance(16)
    let writes = rig.factorWrites
    t.expect(alternates(writes))
    // The next ramp was already designed for the old period; the one after it uses the new one.
    t.expectClose(writes[before.count].time - before.last!.time, 3, tolerance: 1e-6)
    t.expectClose(writes[before.count + 1].time - writes[before.count].time, 3, tolerance: 1e-6)
    t.expectClose(writes[before.count + 2].time - writes[before.count + 1].time, 5, tolerance: 1e-6)
    t.expectEqual(releases(rig), 0)
}

t.test("switching away from breathe releases the factor") {
    let rig = Rig()
    rig.start(.breathe)
    rig.advance(10)
    rig.core.setMode(.steady)
    rig.advance(10)
    t.expectEqual(releases(rig), 1)
    t.expectEqual(rig.calls(isFactor).filter { $0.time > 10.1 }.count, 0)
    t.expect(!rig.status.isAnimating)
}

// MARK: - Battery

t.test("battery level follows charge and pulses below 10 percent") {
    let rig = Rig()
    rig.start(.battery) { $0.brightness = 1 }
    rig.system { $0.batteryPercent = 100 }
    rig.advance(1)
    t.expectEqual(lastTables(rig)?.mapping, .flat(1000))
    rig.system { $0.batteryPercent = 50 }
    rig.advance(3)
    t.expectClose(rig.status.targetNits, 1000 * (0.05 + 0.95 * 0.5), tolerance: 1e-6)
    t.expectEqual(lastTables(rig)?.mapping, .flat(1000 * (0.05 + 0.95 * 0.5)))
    rig.system { $0.batteryPercent = 0; $0.isCharging = true }
    rig.advance(3)
    t.expectClose(rig.status.targetNits, 50, tolerance: 1e-6)
    t.expectEqual(rig.calls(isFactor).count, 0, "charging: steady")
    rig.system { $0.batteryPercent = 9; $0.isCharging = false }
    rig.advance(20)
    let writes = rig.factorWrites
    t.expect(writes.count >= 9)
    t.expect(alternates(writes))
    t.expectClose(writes[1].time - writes[0].time, 2, tolerance: 1e-6)
    let trace = FactorTrace(writes: writes)
    t.expectClose(trace.factor(at: writes[1].time), 0.5, tolerance: 0.01)
    rig.system { $0.batteryPercent = nil }
    rig.advance(5)
    t.expect(!rig.status.isAnimating)
    t.expectEqual(releases(rig), 1)
}

// MARK: - Agents

func agentsRig(_ configure: (inout EffectSettings) -> Void = { _ in }) -> Rig {
    let rig = Rig()
    rig.start(.agents, configure)
    return rig
}

t.test("agents: none and waiting stay steady") {
    let rig = agentsRig()
    rig.advance(5)
    rig.agents(.waiting)
    rig.advance(5)
    t.expectEqual(rig.calls(isFactor).count, 0)
    t.expect(!rig.status.isAnimating)
    t.expectEqual(rig.status.shownActivity, .waiting)
}

t.test("agents: working pulses every 2 s between 1.0 and about 0.5") {
    let rig = agentsRig()
    rig.agents(.working)
    rig.advance(20)
    let writes = rig.factorWrites
    t.expect(alternates(writes))
    t.expectEqual(writes.first?.target, .dark)
    for (a, b) in zip(writes, writes.dropFirst()) { t.expectClose(b.time - a.time, 1, tolerance: 1e-6) }
    let trace = FactorTrace(writes: writes)
    t.expectClose(trace.factor(at: writes[1].time), 0.5, tolerance: 0.01)
    t.expectClose(trace.factor(at: writes[2].time), 0.97, tolerance: 0.01)
    rig.agents(.waiting)
    rig.advance(2)
    t.expectEqual(releases(rig), 1)
    t.expect(!rig.status.isAnimating)
}

t.test("agents: needs you while present is steady, away blinks twice every ~2 s") {
    let rig = agentsRig { $0.agentAwayAfter = 30 }
    rig.agents(.needsYou)
    rig.system { $0.userIdleSeconds = 5 }
    rig.advance(10)
    t.expectEqual(rig.calls(isFactor).count, 0)
    rig.system { $0.userIdleSeconds = 31 }
    let start = rig.elapsed
    rig.advance(6)
    let writes = rig.factorWrites
    t.expect(writes.count >= 8, "writes \(writes.count)")
    t.expect(alternates(writes))
    let rel = writes.map { $0.time - start }
    t.expectClose(rel[0], 0, tolerance: 1e-6)
    t.expectClose(rel[1], 0.12, tolerance: 1e-6)
    t.expectClose(rel[2], 0.24, tolerance: 1e-6)
    t.expectClose(rel[3], 0.36, tolerance: 1e-6)
    t.expectClose(rel[4] - rel[3], 1.6, tolerance: 1e-6)
    t.expectEqual(writes.map(\.target).prefix(4).map { $0 }, [.dark, .lit, .dark, .lit])
    t.expect(maxFlashesPerSecond(flashTimes(writes)) <= 3)
    // The user comes back: blinks stop and the factor is released.
    rig.system { $0.userIdleSeconds = 0 }
    t.expectEqual(releases(rig), 1)
    let count = rig.factorWrites.count
    rig.advance(5)
    t.expectEqual(rig.factorWrites.count, count)
}

t.test("agents: a locked screen counts as away and does not pause agents") {
    let rig = agentsRig()
    rig.agents(.needsYou)
    rig.system { $0.screenLocked = true }
    rig.advance(3)
    t.expect(rig.factorWrites.count >= 4)
    t.expectEqual(rig.status.pausedReason, nil)
    t.expect(rig.status.isAnimating)
}

t.test("preview shows the pattern for 6 s, then returns to the mode") {
    let rig = Rig()
    rig.start(.steady)
    rig.advance(1)
    rig.core.preview(.needsYou)
    let start = rig.elapsed
    t.expect(rig.status.isAnimating)
    t.expectEqual(rig.status.shownActivity, .needsYou)
    rig.advance(5.9)
    t.expect(rig.status.isAnimating)
    rig.advance(0.3)
    t.expect(!rig.status.isAnimating)
    t.expectEqual(rig.status.shownActivity, .none)
    t.expectEqual(releases(rig), 1)
    let last = rig.factorWrites.last!
    t.expect(last.time - start < 6.001, "no keyframe after the preview ended")
    let count = rig.factorWrites.count
    rig.advance(10)
    t.expectEqual(rig.factorWrites.count, count)
}

// MARK: - Music

t.test("music beat: lit, dip, recover; targets alternate; floor follows intensity") {
    for (intensity, floor) in [(1.0, 0.1), (0.7, 0.37), (0.3, 0.73)] {
        let rig = Rig()
        rig.start(.music) { $0.musicIntensity = intensity }
        rig.advance(1)
        rig.beat()
        rig.advance(1)
        let writes = rig.factorWrites
        t.expectEqual(writes.map(\.target), [.dark, .lit], "steady state: no lit before the dip (intensity \(intensity))")
        t.expectClose(writes[0].time, 1.06, tolerance: 1e-6)
        t.expect(writes[1].time - writes[0].time > 0.07 && writes[1].time - writes[0].time < 0.2)
        let trace = FactorTrace(writes: writes)
        let low = trace.samples(from: 1.0, to: 1.5, step: 0.001).min()!
        t.expectClose(low, floor, tolerance: 0.02, "intensity \(intensity)")
        t.expectClose(trace.factor(at: 1.9), 1, tolerance: 0.001)
    }
}

t.test("music: a beat during a dip restores lit first, then dips again") {
    let rig = Rig()
    rig.start(.music)
    rig.advance(1)
    rig.beat()
    rig.advance(0.1) // dip running (dark written at +0.06)
    rig.beat()
    rig.advance(1)
    let writes = rig.factorWrites
    t.expect(alternates(writes), "\(writes)")
    t.expectEqual(writes.map(\.target).prefix(4).map { $0 }, [.dark, .lit, .dark, .lit])
    t.expectClose(writes[1].fade, 0.05, tolerance: 1e-9)
}

t.test("music: flash limiter allows at most 3 flashes per rolling second") {
    let rig = Rig()
    rig.start(.music) { $0.musicStrobe = true }
    rig.advance(1)
    for i in 0..<60 {
        rig.beat(strong: i % 2 == 0)
        rig.advance(0.1)
    }
    rig.advance(1)
    let writes = rig.factorWrites
    t.expect(alternates(writes))
    let flashes = flashTimes(writes)
    t.expect(flashes.count >= 10, "some beats get through (\(flashes.count))")
    t.expect(maxFlashesPerSecond(flashes) <= 3, "max per second \(maxFlashesPerSecond(flashes))")
}

t.test("music: strobe adds one quick pair on strong beats only when enabled") {
    func run(strobe: Bool, strong: Bool) -> [Write] {
        let rig = Rig()
        rig.start(.music) { $0.musicStrobe = strobe }
        rig.advance(1)
        rig.beat(strong: strong)
        rig.advance(2)
        return rig.factorWrites
    }
    t.expectEqual(run(strobe: false, strong: true).count, 2)
    t.expectEqual(run(strobe: true, strong: false).count, 2)
    let strobed = run(strobe: true, strong: true)
    t.expectEqual(strobed.map(\.target), [.dark, .lit, .dark, .lit])
    t.expectClose(strobed[3].time - strobed[2].time, 0.06, tolerance: 1e-6)
}

t.test("music: no beats means no writes; zero intensity does not dip") {
    let rig = Rig()
    rig.start(.music) { $0.musicIntensity = 0 }
    rig.advance(5)
    rig.beat()
    rig.advance(2)
    t.expectEqual(rig.calls(isFactor).count, 0)
    t.expect(rig.status.isAnimating)
}

t.test("entering music while the factor is heading dark settles it lit") {
    let rig = Rig()
    rig.start(.breathe)
    rig.advance(1) // dark target written at 0
    rig.core.setMode(.music)
    rig.advance(1)
    let writes = rig.factorWrites
    t.expectEqual(writes.map(\.target), [.dark, .lit])
}

t.test("beats outside music mode are ignored") {
    let rig = Rig()
    rig.start(.breathe)
    rig.advance(1)
    let before = rig.factorWrites.count
    rig.beat()
    t.expectEqual(rig.factorWrites.count, before)
}

// MARK: - Pauses

t.test("every system update sets the animation gate") {
    let rig = Rig()
    rig.start(.steady)
    rig.system { $0.displayAsleep = true }
    rig.system { $0.displayAsleep = false }
    let gates = rig.calls { if case .allowed = $0 { return true } else { return false } }.map(\.call)
    t.expectEqual(gates, [.allowed(true), .allowed(false), .allowed(true)])
}

t.test("display asleep and lid closed pause with no writes, and resume restarts the pattern") {
    for reason in [PauseReason.displayAsleep, .lidClosed] {
        let rig = Rig()
        rig.start(.breathe)
        rig.advance(7)
        rig.driver.clear()
        rig.system { if reason == .lidClosed { $0.lidClosed = true } else { $0.displayAsleep = true } }
        rig.advance(30)
        t.expectEqual(rig.status.pausedReason, reason)
        t.expect(!rig.status.isAnimating)
        t.expectEqual(rig.driver.calls.map(\.call), [.allowed(false)], "no writes while \(reason)")
        rig.system { $0 = SystemStatus() }
        rig.advance(7)
        t.expectEqual(rig.status.pausedReason, nil)
        t.expect(rig.status.isAnimating)
        let after = rig.driver.calls.map(\.call)
        t.expectEqual(after.prefix(3).map { $0 }, [.allowed(false), .allowed(true), .fade(after.compactMap { if case .fade(let f) = $0 { return f } else { return nil } }.first)])
        t.expect(rig.factorWrites.contains { $0.target == .dark && $0.time > 37 })
    }
}

t.test("screen locked and low power pause everything but agents") {
    for (reason, configure) in [(PauseReason.screenLocked, { (s: inout SystemStatus) in s.screenLocked = true }),
                                (.lowPowerMode, { (s: inout SystemStatus) in s.lowPowerMode = true })] {
        for mode in [LogoMode.breathe, .music] {
            let rig = Rig()
            rig.start(mode)
            rig.advance(4)
            rig.beat()
            rig.advance(0.5)
            rig.driver.clear()
            rig.system(configure)
            t.expectEqual(rig.status.pausedReason, reason)
            rig.advance(10)
            rig.beat()
            rig.advance(1)
            let calls = rig.driver.calls.map(\.call)
            t.expect(calls.contains(.release) || mode == .music, "released on pause (\(mode))")
            t.expectEqual(calls.filter { if case .target = $0 { return true } else { return false } }.count, 0,
                          "no factor writes while paused (\(mode), \(reason))")
        }
        let rig = Rig()
        rig.start(.agents)
        rig.agents(.working)
        rig.system(configure)
        rig.advance(5)
        t.expectEqual(rig.status.pausedReason, nil)
        t.expect(rig.status.isAnimating)
    }
}

t.test("a lit keyboard backlight pauses animation only when the setting is on") {
    let rig = Rig()
    rig.start(.breathe)
    rig.advance(1)
    rig.system { $0.keyboardBacklightLit = true }
    t.expectEqual(rig.status.pausedReason, .keyboardLit)
    t.expect(rig.driver.calls.contains { $0.call == .release })
    var s = EffectSettings()
    s.pauseWhileKeyboardLit = false
    rig.core.setSettings(s)
    t.expectEqual(rig.status.pausedReason, nil)
    t.expect(rig.status.isAnimating)
    rig.core.setSettings(EffectSettings())
    t.expectEqual(rig.status.pausedReason, .keyboardLit)
}

t.test("steady mode reports no environmental pause") {
    let rig = Rig()
    rig.start(.steady)
    rig.system { $0.lowPowerMode = true; $0.screenLocked = true; $0.displayAsleep = true }
    t.expectEqual(rig.status.pausedReason, nil)
}

// MARK: - Power

t.test("setOn(false) cancels, releases, powers off; setOn(true) powers on and resumes") {
    let rig = Rig()
    rig.start(.breathe)
    rig.advance(7)
    rig.driver.clear()
    rig.core.setOn(false)
    t.expectEqual(rig.driver.calls.map(\.call), [.release, .power(.off)])
    t.expectEqual(rig.status.pausedReason, .logoOff)
    t.expect(!rig.status.isOn)
    rig.advance(20)
    t.expectEqual(rig.driver.calls.count, 2)
    rig.driver.clear()
    rig.core.setOn(true)
    t.expectEqual(rig.driver.calls.first?.call, .power(.on))
    rig.advance(7)
    t.expectEqual(rig.status.pausedReason, nil)
    t.expect(rig.status.isOn)
    t.expect(rig.factorWrites.contains { $0.time > 27 })
}

t.test("start with the logo off sets power and does not animate") {
    let rig = Rig()
    rig.start(.breathe, isOn: false)
    rig.advance(10)
    t.expect(rig.driver.calls.contains { $0.call == .power(.off) })
    t.expectEqual(rig.calls(isFactor).count, 0)
    t.expectEqual(rig.status.pausedReason, .logoOff)
}

t.test("unsupported driver: reported, and nothing is written") {
    let rig = Rig(supported: false)
    rig.start(.breathe)
    rig.system { $0.displayAsleep = true }
    rig.core.setOn(false)
    rig.core.setOn(true)
    rig.advance(10)
    rig.core.shutdown(restoreDefaults: true, keepOff: false)
    t.expectEqual(rig.driver.calls.count, 0)
    t.expectEqual(rig.statuses.first?.pausedReason, .unsupported)
}

// MARK: - Shutdown

t.test("shutdown: cancels timers, releases, then restores defaults") {
    let rig = Rig()
    rig.start(.breathe)
    rig.advance(7)
    rig.driver.clear()
    rig.core.shutdown(restoreDefaults: true, keepOff: false)
    t.expectEqual(rig.driver.calls.map(\.call), [.release, .restore(powerOn: true)])
    rig.advance(30)
    t.expectEqual(rig.driver.calls.count, 2)
}

t.test("shutdown keepOff and without restore") {
    let a = Rig()
    a.start(.steady)
    a.driver.clear()
    a.core.shutdown(restoreDefaults: true, keepOff: true)
    t.expectEqual(a.driver.calls.map(\.call), [.release, .restore(powerOn: false)])
    let b = Rig()
    b.start(.steady)
    b.driver.clear()
    b.core.shutdown(restoreDefaults: false, keepOff: true)
    t.expectEqual(b.driver.calls.map(\.call), [.release, .power(.off)])
    let c = Rig()
    c.start(.steady)
    c.driver.clear()
    c.core.shutdown(restoreDefaults: false, keepOff: false)
    t.expectEqual(c.driver.calls.map(\.call), [.release, .power(.on)])
}

// MARK: - Late wake-up

t.test("a long stall re-bases the pulse instead of replaying missed keyframes") {
    let rig = Rig()
    rig.start(.breathe)
    rig.advance(1)
    let count = rig.factorWrites.count
    rig.clock.now += 100 // process suspended: the clock jumps but no wake-up ran
    rig.advance(0.01)
    let writes = rig.factorWrites
    t.expect(writes.count <= count + 2, "no burst of catch-up writes (\(writes.count))")
    t.expect(alternates(writes))
}

// MARK: - Real engine on real timers

t.test("EffectEngine on real timers: breathes, publishes status, shuts down synchronously") {
    let start = ProcessInfo.processInfo.systemUptime
    let driver = RecordingDriver(time: { ProcessInfo.processInfo.systemUptime - start })
    let engine = EffectEngine(driver: driver)
    var statuses: [EngineStatus] = []
    engine.onStatusChange = { statuses.append($0) }
    var s = EffectSettings()
    s.breathePeriod = 3
    engine.start(isOn: true, mode: .breathe, settings: s)
    // Pump the main run loop so status updates are delivered.
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.8))
    let writes = driver.calls.compactMap { entry -> (TimeInterval, FactorTarget)? in
        if case .target(let target) = entry.call { return (entry.time, target) } else { return nil }
    }
    t.expectEqual(writes.map(\.1), [.dark, .lit], "keyframes at 0 and 1.5 s")
    if writes.count == 2 {
        t.expectClose(writes[1].0 - writes[0].0, 1.5, tolerance: 0.02)
    }
    t.expectEqual(statuses.last?.mode, .breathe)
    t.expectEqual(statuses.last?.isAnimating, true)
    driver.clear()
    engine.shutdown(restoreDefaults: true, keepOff: false)
    t.expectEqual(driver.calls.map(\.call), [.release, .restore(powerOn: true)])
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.7))
    t.expectEqual(driver.calls.count, 2, "timer is dead after shutdown")
}

t.finish()
