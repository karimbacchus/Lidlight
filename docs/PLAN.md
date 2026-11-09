# Lidlight — plan

Lidlight is a macOS menu bar app that controls the glowing logo on the lid of the MacBook Pro with
PROLED XDR Display: set its brightness, turn it off, or give it a mode (Steady, Breathe, Battery, Music,
Agents). It is an original implementation of the feature set of backglow.app — own name, own design, own
copy, no Apple logo artwork. Not affiliated with Apple.

Read `docs/HARDWARE.md` before touching anything that talks to corebrightnessd.

## 1. Product spec

### Menu bar
- Icon (template image, drawn in code): **filled dot** = logo on · **ring** = logo off · **dot with a small
  wave** = an animated mode (Breathe/Music/Agents) is running.
- Click → popover. **Option-click** → toggle the logo on/off. Global shortcut **⌃⌘B** → toggle on/off.

### Popover
- Header: app name, live readout ("Logo · 742 nits" from `LogoState.finalNits`, polled ~2 Hz while open),
  master on/off switch (writes `LEBacklightMode`).
- Brightness slider (perceptual, 0…1 → 3…1000 nits; disabled when off).
- Mode list: Steady, Breathe, Battery, Music, Agents (SF Symbol, title, one-line subtitle, checkmark).
- Mode controls:
  - Breathe: speed slider, 3…10 s per breath (default 6; labels "Slow"/"Fast").
  - Music: intensity slider; strobe toggle ("flashes are capped at 3 per second"); permission row when
    system audio capture isn't granted (button opens System Settings › Privacy & Security ›
    Screen & System Audio Recording).
  - Agents: Claude Code connection row (Connect/Disconnect) and a live line ("2 sessions · 1 working").
  - Battery: current charge line.
- Paused banner when the engine reports a `PauseReason` (e.g. "Paused — Low Power Mode").
- Simulation banner when the driver is simulated ("No logo on this Mac — preview mode" + Show preview).
- Footer: Settings…, Quit.

### Settings window
- General: Open at login (SMAppService), global shortcut on/off, Show preview window.
- Logo: Full brightness in any room; Pause effects while the keyboard backlight is on; "Restore Apple's
  logo settings" (driver.restoreSystemDefaults).
- Agents: Connect/Disconnect, "Blink when I've been away for N seconds", test buttons (Working / Needs you →
  `engine.preview`).
- About: version, privacy (no network, audio never leaves the Mac, hooks only report state), "Not made by
  or affiliated with Apple."
- (Experimental, phase 3) Keep glowing when the lid is closed.

### Quit
If the logo is off, ask "Keep the logo off after Lidlight quits?" — Keep Off / Turn On. Then
`engine.shutdown(restoreDefaults: true, keepOff:)`: Apple's tables back, overrides cleared, power on
unless kept off.

### Modes (what the logo does)
| Mode | Behavior |
|---|---|
| Steady | Constant level from the brightness slider. |
| Breathe | Smooth fade out/in, one breath per `breathePeriod` seconds, peak = slider level. |
| Battery | Level follows charge (full = slider level, empty = ~5 %); below 10 % and not charging, a slow pulse. |
| Music | Flashes on each beat of system audio and decays between beats; intensity sets how deep the decay goes; optional strobe double-flash on strong beats. Max 3 flashes/s. |
| Agents | No sessions or waiting → steady (soft glow). Working → gentle pulse (~2 s, 50 % depth). Needs you **and** user idle ≥ `agentAwayAfter` (or screen locked) → quick double blinks every ~2 s. |

Pauses (engine): display asleep or lid closed → nothing can be shown (driver animation gate off).
Screen locked or Low Power Mode → pause all animations except Agents. Keyboard backlight lit (and the
setting is on) → pause animations. Paused = factor released (lit), steady level kept.

## 2. How the hardware is driven

Three verified primitives (details and numbers in docs/HARDWARE.md):

1. **Power** — `LEBacklightMode` 0/2. Instant. NVRAM writes → user actions only, ≥ 1 s apart.
2. **Level** — the three tables. Steady level L ⇒ mapping = flat(L), minRestriction = flat(0),
   maxRestriction = flat(1000) if "Full brightness in any room" else Apple's. Persisted, applied lazily
   (next display-brightness update / ambient-light update). Write at most once per 2 s, only on change.
3. **Animation** — the factor channel: `LEPWMFactorFadeDuration` + `DisplayLogicalState` 1/2. Instant,
   smooth (60 Hz inside corebrightnessd), no NVRAM. Effects are expressed as **keyframes**
   `(at time t: fade duration d, target lit|dark)`; interrupting a ramp early gives partial depth.

Brightness slider → nits: `nits = 3 + (1000 − 3) · s^2.2`.

## 3. Architecture

SwiftPM package, Command Line Tools only (no Xcode). One module per owner; contracts in `LidlightKit`.

```
LidlightKit (contracts) ◀── every module
CoreBrightnessBridge (ObjC) ◀── LidlightDriver
LidlightApp  = composition root: Driver + Engine + System + Agents + Audio + UI
lidlightctl  = composition root: Driver (DriverCLI, guardian) + Agents (agent-event) + Audio (audio-test)
```

| Module | Owner | Key public types (names fixed by the scaffold) |
|---|---|---|
| LidlightKit | lead | `LogoDriving`, `LogoControlling`, `SystemMonitoring`, `AgentMonitoring`, `ClaudeHooksManaging`, `BeatSource`, value types |
| CoreBrightnessBridge + LidlightDriver | Driver agent | `CoreBrightnessLogoDriver`, `SimulatedLogoDriver`, `CoreBrightnessKeyboardProbe`, `DriverCLI`, `GuardianLauncher`, `SafetyRecovery` |
| LidlightEngine | Engine agent | `EffectEngine` |
| LidlightSystem | System agent | `SystemMonitor` |
| LidlightAgents | Agents agent | `AgentMonitor`, `ClaudeHooksInstaller`, `AgentHookCommand` |
| LidlightAudio | Audio agent | `SystemAudioBeatSource`, `AudioCLI` |
| LidlightUI | UI agent | `AppModel`, `AppController` |
| LidlightApp, lidlightctl, Package.swift, scripts, docs | lead | composition roots, bundling |

Rules for parallel work:
- Edit only files in your own module(s) and your own `Checks/<Module>Checks`. Do not edit
  `Package.swift`, `LidlightKit`, composition roots or another module. If you need a contract change,
  implement around it and describe the change in your final report.
- Keep the scaffold's public names and initializers exactly.
- Build only your target with your own scratch path, e.g.
  `swift build --target LidlightEngine --scratch-path .build-engine` and
  `swift run --scratch-path .build-engine EngineChecks`. Never `rm -rf .build`.
- Only the Driver agent writes to corebrightnessd. Everyone else uses `SimulatedLogoDriver` or fakes.
- The `package` access modifier is available for things checks need but the app shouldn't see.

## 4. Module specs

### Driver (CoreBrightnessBridge, LidlightDriver)
- `CoreBrightnessLogoDriver`: `init?()` nil unless `LEBacklightMode` and `LEPWMState` read non-nil.
  Serial queue for all XPC. Validates tables (`NitsTable.isValid`), skips unchanged writes, rate-limits
  power (≥ 1 s) and tables (coalesce, ≤ 1 write per key per 2 s). Animation gate per the protocol.
  Writes the dirty marker (`AppPaths.dirtyMarkerURL`, JSON with what was changed) before the first
  modifying write; `restoreSystemDefaults` writes Apple's tables (skip if already equal), fade 0,
  logical state 2 (only if gate open), power on if asked, then removes the marker.
  `previewLevel()` = cached `finalNits / 1000`, refreshed ≤ 10 Hz.
- `SimulatedLogoDriver`: models the full pipeline in memory — tables (applied immediately), power, and
  the factor ramp using the measured `FactorRampModel`. `previewLevel()` evaluates the model at "now", so
  the preview window animates smoothly. Thread-safe.
- `FactorRampModel` (public, value type): factor(t) for a ramp from f0 toward target with duration d,
  fitted to measurements; plus inverse helpers (time to reach a factor). Shared with the engine by
  copying the fitted constants into docs/HARDWARE.md (the engine owns its own copy of the model).
- `CoreBrightnessKeyboardProbe`: lit = brightness > 0.01 && !suppressed && !dimmed for the built-in keyboard.
- `DriverCLI` (`lidlightctl`): `help`, `status [--json]`, `on`, `off`, `level <nits>`, `tables`,
  `restore`, `fade <dark|lit> [seconds]`, `measure-ramp [seconds…]` (samples Factor at ~100 Hz in-process,
  prints CSV + fitted τ), `guard --parent-pid <pid>` (see guardian).
- Guardian: `GuardianLauncher.launch(helperURL:)` starts `lidlightctl guard --parent-pid <pid>` with a
  pipe on stdin. The guard blocks reading stdin; on EOF (app exited/crashed) it restores defaults if the
  dirty marker exists (respecting a `keepOff` flag the app writes into the marker), then exits. It ignores
  SIGINT/SIGTERM/SIGHUP. `SafetyRecovery.recoverIfNeeded` does the same at launch.

### Engine (LidlightEngine)
- Main-thread API (`LogoControlling`). Internally a keyframe scheduler on a `DispatchSourceTimer`
  (strict, 0 leeway), writes go to the driver on a serial queue (never block main).
- Clock abstraction so checks can run with a virtual clock and a recording fake driver.
- Steady level → tables (debounced 300 ms, ≤ 1 write / 2 s). Animation → keyframes.
- Breathe: alternate dark/lit every half period; choose fade duration and reversal timing with the ramp
  model so the wave is smooth and the trough is near 0 but not a long flat.
- Music: per beat: lit with a ~40 ms fade, then dark with a decay whose length/depth follows intensity;
  `handleAudioLevel` can gently modulate between beats. Strobe: on strong beats an extra dip.
- Agents: patterns per spec. Away = `system.userIdleSeconds ≥ settings.agentAwayAfter` or screen locked.
- Flash limiter: at most 3 dark→lit "flashes" (dark phases < 0.5 s) per rolling second; drop extras.
- Pause rules per spec; on pause/resume/mode change call `driver.releaseFactor()` as appropriate;
  `driver.setAnimationAllowed(system.animationPossible)` on every system update.
- `setOn(false)`: stop animations, `releaseFactor`, `setPower(.off)`. `setOn(true)`: power on, resume.
- `shutdown`: stop timers, release factor, restore defaults, power per `keepOff`.
- Publish `EngineStatus` on change (main thread).

### System (LidlightSystem)
- Display sleep/wake: `NSWorkspace` screensDidSleep/DidWake + `CGDisplayIsAsleep(CGMainDisplayID())`
  polling backup; built-in display off when the lid is closed with an external display.
- Lock: distributed notifications `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`, plus
  `CGSessionCopyCurrentDictionary` (`CGSSessionScreenIsLocked`) at start.
- Low Power Mode: `ProcessInfo.isLowPowerModeEnabled` + `.NSProcessInfoPowerStateDidChange`.
- Lid: IORegistry `IOPMrootDomain` `AppleClamshellState` (interest notification or 2 s poll).
- Battery: IOPowerSources (`IOPSCopyPowerSourcesInfo`, run-loop notification).
- Idle: `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)` (or
  `HIDIdleTime`), sampled every 2 s.
- Thermal: `ProcessInfo.thermalState` + notification.
- Keyboard lit: injected `KeyboardBacklightProbing`, sampled every 2 s.
- Emit only on change, on the main thread.

### Agents (LidlightAgents)
- `AgentHookCommand.run`: read stdin JSON (`session_id`, `hook_event_name`, `cwd`, `notification_type`/
  `message` …), map event → activity, write `<session>.json` atomically into the spool, post the Darwin
  notification (`notify_post`). SessionEnd deletes the record. Print nothing on stdout, always exit 0,
  finish in < 50 ms, never throw.
  Mapping: SessionStart → waiting · UserPromptSubmit / PreToolUse / PostToolUse / SubagentStop → working ·
  Notification (permission prompt, idle prompt, any other) → needsYou · PermissionRequest → needsYou ·
  Stop → waiting · SessionEnd → remove. Verify current event names against Claude Code's hooks docs.
- `AgentMonitor`: `notify_register_dispatch` + 5 s sweep timer; aggregates records: needsYou > working >
  waiting; working without events for 10 min → waiting; records older than 12 h → deleted.
- `ClaudeHooksInstaller`: settings path `$CLAUDE_CONFIG_DIR/settings.json` or `~/.claude/settings.json`.
  Connect = merge one hook entry per event `{"type":"command","command":"'<helper>' agent-event","timeout":5}`
  (matcher "*" where matchers apply), preserving all other content; backup the file first; idempotent;
  identify ours by the `agent-event` command on a path ending in `lidlightctl`. Disconnect removes only
  ours and empty containers we created. Status detects not installed / installed / needs update (different
  path). Checks use temp files only — never touch the real settings file.

### Audio (LidlightAudio)
- macOS 14.2+ Core Audio process tap of all system output (`CATapDescription(stereoGlobalTapButExcludeProcesses: [])`),
  private aggregate device with the tap, IOProc on a real-time-safe path (no allocation/locks/ObjC there),
  hand frames to an analysis queue via a lock-free ring buffer.
- `BeatDetector` (pure, testable): low-pass/band energy (≈ 40–150 Hz) with Accelerate, envelope follower,
  adaptive threshold onset detection with a ~120 ms refractory period, strength relative to recent beats,
  `isStrong` for the top beats; level output ~30 Hz.
- Permission: `Info.plist` has `NSAudioCaptureUsageDescription`; report `.denied` when the tap fails
  for authorization reasons.
- `AudioCLI` (`lidlightctl audio-test [seconds]`): runs capture and prints beats/levels.
- Checks with synthetic signals (click tracks at known BPM, silence, noise) only — no live capture.

### UI (LidlightUI)
- `AppModel` (`ObservableObject`, main thread): loads/saves `AppSettings` (UserDefaults JSON), wires
  service callbacks → engine, starts/stops the beat source when entering/leaving Music, hooks
  connect/disconnect, live readouts, quit flow.
- `AppController`: `NSStatusItem` + `NSPopover` (SwiftUI content), icon drawing (dot/ring/wave), option-
  click toggle, Carbon `RegisterEventHotKey` for ⌃⌘B, settings window, preview window, login item,
  `applicationShouldTerminate` quit flow.
- Preview window: stylized lid with an abstract glowing mark; brightness = `preview.previewLevel()` in a
  60 fps `TimelineView`.
- Polished, native look: system materials, SF Symbols, standard spacing, dark/light aware.
- Run only with `--simulate` (or `swift run LidlightApp --simulate`) while developing.

## 5. Phases

| Phase | Work | Who |
|---|---|---|
| 0 | Research, hardware probing, scaffold, contracts, docs | lead (done) |
| 1 | Driver · Engine · System · Agents · Audio · UI, in parallel | 6 Sonnet agents |
| 2 | Wire composition roots, build app, hardware smoke test, fix integration issues | lead (+ fix agents) |
| 3 | Instant level apply (spike); keep glowing with the lid closed (needs a user-in-the-loop lid test); live Music permission test; dark-room keyboard flicker check; Developer ID signing/notarization | follow-ups |

Out of scope: payments/licensing (the original has a paid Pro tier — everything is unlocked here),
auto-update, localization, a marketing website.

## 6. Done means

- `make app` builds `build/Lidlight.app`; `make checks` passes.
- On this Mac: on/off, Steady level (after the next brightness update), Breathe, Agents patterns and the
  quit/restore flow work and leave Apple's settings intact; NVRAM counters only move on user on/off.
- In `--simulate`: every mode animates the preview window.
