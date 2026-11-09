# Lidlight

A menu bar app for the glowing logo on the lid of the MacBook Pro with PROLED XDR Display.
Set how bright it glows, turn it off, or give it a mode:

- **Steady** — a constant glow at the brightness you choose.
- **Breathe** — fades in and out, like an old sleep light.
- **Battery** — dims as your charge runs down.
- **Music** — pulses to the beat of whatever your Mac plays (system audio, never the microphone).
- **Agents** — a status light for Claude Code: soft glow while waiting, a pulse while working,
  double blinks when it needs you and you've stepped away.

Lidlight is not made by or affiliated with Apple.

## Build

Requires macOS 14+ and the Xcode Command Line Tools (Xcode is not needed).

```bash
make app        # build/Lidlight.app, ad-hoc signed
make run        # build and open it
make run-sim    # run with a simulated logo (no hardware writes)
make checks     # run every module's checks
make install    # copy to ~/Applications
```

`lidlightctl` (inside the app at `Contents/Helpers/lidlightctl`) is a small CLI for status and testing:
`lidlightctl status`, `lidlightctl off`, `lidlightctl restore`, …

## How it works

macOS sets the logo's brightness itself (from the screen brightness and the room light) and offers no
setting for it. Lidlight changes the logo's own brightness settings in `corebrightnessd` through the
private CoreBrightness framework. It never changes your screen's brightness, needs no password, and puts
Apple's settings back when it quits. See [docs/HARDWARE.md](docs/HARDWARE.md) for the details and
[docs/PLAN.md](docs/PLAN.md) for the design.

## Removing it

1. Turn the logo on (if you turned it off) and quit Lidlight — it restores Apple's logo settings.
2. In Settings, click Disconnect for Agents (removes the Claude Code hooks).
3. Delete the app.

If the logo stays dark: `lidlightctl restore`, or Apple's command
`sudo defaults delete com.apple.CoreBrightness LEBacklightMode`.
