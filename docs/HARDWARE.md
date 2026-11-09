# Logo light hardware notes

Findings from probing a **Mac17,12 (MacBook Pro, M5 Pro, Built-in PROLED XDR Display) on macOS 27.2**,
2026-11-09. Everything here was measured on that machine; treat it as the ground truth for the driver
and re-verify after macOS updates.

## Safety rules (read first)

These are non-negotiable for every module and every experiment:

1. **Never write `DisplayPowerStateEvent`.** The display module acts on it. Writing `3` during research
   made corebrightnessd treat the built-in display as going to sleep and drive it to SDR 0 nits — the
   screen went dark for ~35 s until `1` (WillWake) then `2` (DidWake) were written. The bridge refuses
   this key; keep it that way.
2. **Never change the display's brightness** (`DisplayServicesSetBrightness`, `DisplayServicesBrightness`,
   `DisplayBrightnessFactor*`, CoreDisplay). A brightness write is logged as a *user brightness commit* and
   corebrightnessd adjusts the user's auto-brightness curve ("Adjusting AAB curve for preference point").
3. **Never write `LEBacklightMode` for effects.** Every change makes corebrightnessd write two NVRAM
   variables (`bklb-backlight-dc`, `bklb-backlight-frequency`; counter went 147 → 156 over 9 changes).
   Only the user's on/off switch may change it, rate-limited. Blink-by-mode-toggle (as some tools do)
   wears NVRAM.
4. **Never write `LEBacklightMode = 1`.** corebrightnessd's store logs it as mode 0 while the logo stays
   lit — an inconsistent state.
5. **Never write `ClamshellUpdate`** (shared with the keyboard backlight and color modules) — reserved
   for the experimental lid-closed feature, which needs a user-in-the-loop test first.
6. Write `DisplayLogicalState` **only `1` or `2`**, **only while the built-in display is awake and the
   lid is open**, and **always leave it at `2`** when done.
7. No `sudo`, no NVRAM writes, no `KeyboardBrightnessClient` setters.
8. Always leave the machine as you found it: Apple's tables, fade override 0, logical state 2, mode 2
   (unless the user deliberately turned the logo off).

## The hardware

- The logo is a white LED driven by PWM: IORegistry node `bklb-backlight@0` (`AppleARMPWMDevice`) under
  `AppleS5L8920XFPWM`. NVRAM keeps `bklb-backlight-enabled`, `bklb-backlight-dc`, `bklb-backlight-frequency`.
- It is driven exclusively by `corebrightnessd` (classes `CBLEPWMContainer`, `CBLEPWMControlModule`,
  `CBLEPWMAutoBrightnessModule`, `CBLEPWMNitsRateLimiter`, `CBLEPWMNitsMultiplier`, `CBLEBacklightModeStore`,
  `BacklightDriverPWM`). There is no client path to the PWM device itself.
- "Keyboard Backlight 2" (KeyboardUniqueID 13) is **not** the logo; it is a second keyboard-area light.
- Apple's only documented control: `sudo defaults write com.apple.CoreBrightness LEBacklightMode -int 0`.

## Access path

`BrightnessSystemClient` in `/System/Library/PrivateFrameworks/CoreBrightness.framework` (load with dlopen):

- `-copyPropertyForKey:` (returns +1) and `-setProperty:forKey:` (returns BOOL). Synchronous XPC, ~1 ms.
- Works from an ordinary user process, ad-hoc signed, **no root, no entitlements**.
- Client writes are broadcast to every corebrightnessd module (display, auto-brightness, keyboard,
  color, `BLC_SKL` = the logo); each decides whether to act. Check the log to see who acted.

Wrapped by `Sources/CoreBrightnessBridge` (`LLCoreBrightness`).

## The brightness pipeline

```
display SDR nits ──mapping table──▶ PWMNitsPreRestriction
                                       │ clamp [min(lux), max(lux)]      ← restriction tables
                                       ▼
                                   rate limiter (follow tau) ─▶ AppliedNits
                                       × NitsMultiplier (charger/enclosure; 1.0 observed)
                                       × Factor (0…1, animation/fade channel)
                                       ▶ FinalNits ─▶ PWM duty cycle
LEBacklightMode 0 ─▶ FinalNits 0 immediately ("backlight confirmed off (mode 0)")
```

corebrightnessd logs it as e.g.
`LE PWM state: ALS 4170.0 lux | display 609.2 -> LE 1000.0 nits, restrictions [1000.0 .. 1000.0] | limited 1000.0 x boost 1.000 (charger 2) x fade 1.000 -> driver 1000.0 nit`.

## Keys

| Key | Type | R/W | Effect | Notes |
|---|---|---|---|---|
| `LEPWMState` | dict | R | live pipeline | `FinalNits, AppliedNits, Factor, DisplayNits, Lux, MinNitsRestriction, MaxNitsRestriction, PWMNitsPreRestriction, NitsMultiplier, ChargerState` |
| `LEBacklightMode` | int | R/W | 0 off, 2 on (auto) | Instant (~1 ms). 2 NVRAM writes per change. Default 2. |
| `LEPWMBrightnessNitsMapping` | `[[x,y]]` | R/W | display nits → logo nits | Validated (`mapping_table_is_valid`), saved to corebrightnessd's defaults, applied at the **next display-brightness update**. |
| `LEPWMLuxToMinNitsRestrictionMapping` | `[[x,y]]` | R/W | lux → min nits | Saved; applied at the **next ambient-light update** of the logo module (rare: 4 distinct lux values in 3 h). |
| `LEPWMLuxToMaxNitsRestrictionMapping` | `[[x,y]]` | R/W | lux → max nits | Same as above. Apple caps dark rooms at 180 nits. |
| `LEPWMFactorFadeDuration` | double s | W | duration for **all** factor ramps ("constant, everywhere"); 0 → Apple's per-sequence curves | In-memory. Every other module ignores it. Reads back nil. |
| `DisplayLogicalState` | int | W | `1` Blank → factor ramps to 0; `2` Unblank → factor ramps to 1 | Display and auto-brightness modules ignore it (result=0). **The keyboard backlight container acts on it** ("Logical display state update = 1", "User activity 0"). No NVRAM writes (counter unchanged over 3 fade cycles). |
| `DisplayPowerStateEvent` | int | **FORBIDDEN** | display module treats it as real sleep/wake | See safety rule 1. |
| `ClamshellUpdate` | int | reserved | 0 open / 1 closed | Logo, keyboard and color modules act; display ignores. |

Enum orders observed in corebrightnessd strings/logs: logical state `0 Unpowered, 1 Blank, 2 Unblank,
3 Dim, 4 Undim, 5 Fade, 6 Unfade`; the logo factor is 0 when logical state < 2.

### Apple's default tables (this Mac)

```
mapping:        [[0,0],[0.1,12.5],[16.84,12.5],[34.12,28.62],[50,45.37],[69.11,65.52],[140,150],[300,300],[600,1000],[FLT_MAX,1000]]
minRestriction: [[0,12.5],[190,150],[560,300],[1350,1000],[FLT_MAX,1000]]
maxRestriction: [[0,180],[190,1000],[FLT_MAX,1000]]
```

Exact float values are in `LogoTables.appleDefaults`. After the research session these keys exist in
corebrightnessd's (root) defaults with exactly these values — equivalent to Apple's built-in defaults.

## What controls exist (and their limits)

1. **On/off — instant.** `LEBacklightMode` 0/2. User actions only (NVRAM).
2. **Level — lazy.** The three tables. There is no client-side "apply now": mode toggles, re-writing
   `DisplayBrightnessFactor`, and writing `ChargerState`/`CBDisplayInfo` do not trigger re-evaluation.
   The mapping is re-evaluated on every display-brightness transaction (~120 Hz while auto-brightness
   ramps, otherwise every few minutes); restrictions only when the logo module's lux changes.
   Finding a side-effect-free "apply now" trigger is open work (docs/PLAN.md, phase 3).
3. **Animation — instant and smooth.** The factor channel: set `LEPWMFactorFadeDuration` (seconds), then
   write `DisplayLogicalState` 1 or 2. corebrightnessd ramps the factor at 60 Hz and multiplies FinalNits.
   Reversing mid-ramp starts a new ramp from the current factor.

### Measured factor ramp (driver agent, in-process sampling at ~100 Hz)

`lidlightctl measure-ramp` (durations 0.3, 1, 2, 4 s, both directions; CSV + fit). Normalized by the
fade duration `d`, all runs coincide: the ramp is **S-shaped with a slow start, not a pure exponential**,
and reaches the target exactly at `d` (within 1 % at about 0.91 d). Fraction of the distance still
remaining at u = t/d (mean of the 2 s and 4 s runs; 0.3 s and 1 s runs are within 0.03):

| u | 0.05 | 0.1 | 0.2 | 0.3 | 0.4 | 0.5 | 0.6 | 0.7 | 0.8 | 0.9 | 1.0 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| remaining | 0.97 | 0.88 | 0.66 | 0.45 | 0.29 | 0.18 | 0.11 | 0.06 | 0.03 | 0.012 | 0 |

Fits (RMS error of remaining, 1400 samples, d >= 1 s):

| form | parameter | RMS |
|---|---|---|
| `FactorRampModel` (normalized exponential) | **k = 2.3** (now `FactorRampModel.measured`) | 0.058 |
| normalized critically damped response, `g(x) = (1+x)e^-x`, `remaining(u) = (g(a u) - g(a)) / (1 - g(a))` | a = 5.9 | **0.011** |

The critically damped form is the better model (slow start, hard stop at `d`); `k = 2.3` is the best the
current exponential API can do and is only a rough approximation (error up to ~0.1 near u = 0.1).

Other findings (macOS 27.2, Mac17,12):

- **Latency**: `setProperty` returns in ~0.01 ms (p50 and p95; the XPC send is one-way), `copyProperty`
  ~0.07 ms p50 / 0.10 ms p95. A write shows up in `Factor` after **~20-24 ms** (next 60 Hz tick).
- **b. Fade duration changes do not affect a ramp in flight.** The duration is latched when the target is
  written (2 s ramp, fade set to 0.3 or 0 at 0.5 s: unchanged, still settles at 1.82 s; 1 s ramp, fade set
  to 4: unchanged). So `releaseFactor` can write the target and then clear the override immediately.
- **c. Re-writing the same target while a ramp toward it is in flight is ignored** (with a new duration or
  the same one): no restart, no re-timing. Only a change of target starts a ramp.
- **d. Mid-ramp reversal** starts a new ramp from the current factor, lasting the full current fade
  duration, with zero initial velocity (it dwells ~0.1 s before moving). Reversal at 0.5 s of a 2 s fade
  (factor 0.54) reached 1 % of lit after 1.69 s; at 0.25 s (factor 0.84) after 1.41 s.
- The logo module accepted a Blank/Unblank pair while the lid was closed ("Unpowered -> Blank ->
  Unblank" in the log) and the factor stayed 0 (the system owns it): never rely on the write working then.

## Pauses the system imposes

- Display sleep: "nits frozen (WillSleep)", factor ramps to 0 over ~0.14 s, logical state → Unpowered.
- Display wake: factor ON ramp is gated until the first lit frame ("display ready gate"), then ~0.3 s ramp.
- Display idle-dim: logical state → Dim (logo stays lit).
- Lid closed: "nits frozen (clamshell closed)", factor → 0.
- Any real display event overwrites a spoofed logical state, so the system re-syncs on its own.

## Keyboard backlight interplay

`DisplayLogicalState` writes reach the keyboard backlight container, and the effect is drastic (measured
in an 87-lux room with the user typing): **Blank switches the keyboard backlight fully off instantly**
(`backlightLevelForKeyboard` 8.46 → 0, `brightnessForKeyboard` → 0) and **Unblank switches it back on**.
Any effect with dark phases therefore blinks a lit keyboard backlight.

Signals during a Blank phase: `brightness` and the live level read 0 (fooled by our own write);
`dimmed` keeps tracking user activity (0 while typing, 1 after the keyboard's 10 s idle dim) and
`saturated` keeps tracking room light (1 in a bright room). So "the keyboard would be lit" =
`!dimmed && !saturated`, which is what `CoreBrightnessKeyboardProbe` reports.

Mitigation: effects pause while that is true (setting "Pause effects while the keyboard backlight is on",
default on). Agents' "needs you" blinks only run when the user is away, when the keyboard is dimmed anyway.
Keyboard IDs on this Mac: 95158272 (built-in keyboard), 13 (second key light).

## Useful commands

```bash
# live logo log (info level is in-memory only; use `log stream` to watch)
/usr/bin/log stream --style compact --info --predicate 'process == "corebrightnessd" AND subsystem BEGINSWITH "com.apple.CoreBrightness.CBLE"'
# who acted on a key you wrote
/usr/bin/log show --last 1m --style compact --info --predicate 'process == "corebrightnessd"' | grep -E 'result=|CBLE'
# NVRAM write counters for the logo
ioreg -l -w0 | grep -o '"0[12]:bklb-backlight-[a-z]*"={[^}]*}' | sort -u
```

Note: in zsh `log` is a builtin — always call `/usr/bin/log`.
