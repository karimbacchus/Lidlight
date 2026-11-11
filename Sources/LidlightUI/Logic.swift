import AppKit
import LidlightKit

// Pure presentation logic: no services, no views. Everything here is covered by UIChecks.

// MARK: - Brightness and speed sliders

/// The perceptual brightness slider's value label.
package enum BrightnessCurve {
    /// "742 nits"
    package static func label(forSlider position: Double) -> String {
        "\(Int(LogoLimits.nits(forBrightness: position).rounded())) nits"
    }
}

/// The Breathe speed slider: the right end is fast (3 s per breath), the left end slow (10 s).
package enum BreatheSpeed {
    package static var range: ClosedRange<Double> { EffectSettings.breathePeriodRange }

    /// Slider position 0 (slow) ... 1 (fast) → seconds per breath, in half-second steps.
    package static func period(forSlider position: Double) -> Double {
        let s = min(max(position, 0), 1)
        let raw = range.upperBound - s * (range.upperBound - range.lowerBound)
        return (raw * 2).rounded() / 2
    }

    package static func slider(forPeriod period: Double) -> Double {
        let p = min(max(period, range.lowerBound), range.upperBound)
        return (range.upperBound - p) / (range.upperBound - range.lowerBound)
    }

    /// "6 s per breath"
    package static func label(forPeriod period: Double) -> String {
        let text = period.rounded() == period ? String(Int(period)) : String(format: "%.1f", period)
        return "\(text) s per breath"
    }
}

package enum Percent {
    package static func label(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
}

// MARK: - Texts

package enum Texts {
    /// Header readout, e.g. "Logo · 742 nits".
    package static func readout(state: LogoState?, isOn: Bool) -> String {
        guard isOn else { return "Logo · Off" }
        guard let state else { return "Logo · —" }
        return "Logo · \(Int(state.finalNits.rounded())) nits"
    }

    /// Banner text for an engine pause; nil when no banner is warranted (also for `.logoOff`,
    /// which the master switch already explains).
    package static func pauseBanner(_ reason: PauseReason?) -> String? {
        switch reason {
        case nil, .logoOff?: return nil
        case .displayAsleep?: return "Paused — display asleep"
        case .lidClosed?: return "Paused — lid closed"
        case .screenLocked?: return "Paused — screen locked"
        case .lowPowerMode?: return "Paused — Low Power Mode"
        case .keyboardLit?: return "Paused — keyboard backlight on"
        case .unsupported?: return "Paused — logo not available"
        }
    }

    /// Live Agents line, e.g. "2 sessions · 1 working".
    package static func agentsLine(_ snapshot: AgentSnapshot) -> String {
        guard snapshot.sessions > 0 else { return "No Claude Code sessions" }
        var parts = [snapshot.sessions == 1 ? "1 session" : "\(snapshot.sessions) sessions"]
        if snapshot.working > 0 { parts.append("\(snapshot.working) working") }
        if snapshot.needingYou > 0 { parts.append("\(snapshot.needingYou) need\(snapshot.needingYou == 1 ? "s" : "") you") }
        return parts.joined(separator: " · ")
    }

    /// Battery mode line, e.g. "Battery 82% · charging".
    package static func batteryLine(_ status: SystemStatus) -> String {
        guard let percent = status.batteryPercent else { return "No battery in this Mac" }
        let state = status.isCharging ? "charging" : (status.onBattery ? "on battery" : "plugged in")
        return "Battery \(Int(percent.rounded()))% · \(state)"
    }

    package static func hooksSummary(_ status: HooksStatus) -> String {
        switch status {
        case .notInstalled: return "Not connected"
        case .installed: return "Connected"
        case .needsUpdate: return "Connected — update needed"
        case .error(let message): return message
        }
    }

    package static func permissionText(_ permission: AudioCapturePermission) -> String? {
        switch permission {
        case .granted: return nil
        case .notDetermined: return "Needs permission to hear system audio."
        case .denied: return "System audio access is off for Lidlight."
        case .unsupported: return "System audio capture needs macOS 14.2 or later."
        }
    }

    package static func awayLabel(seconds: Double) -> String {
        "Blink when I've been away for \(Int(seconds.rounded())) seconds"
    }
}

// MARK: - Which controls each mode shows

package enum ModeControl: Equatable {
    case breatheSpeed
    case musicPermission
    case musicIntensity
    case musicStrobe
    case agentsConnection
    case agentsLive
    case batteryCharge
}

extension LogoMode {
    /// Controls shown under the mode list for this mode, in order.
    package func controls(audioPermission: AudioCapturePermission) -> [ModeControl] {
        switch self {
        case .steady: return []
        case .breathe: return [.breatheSpeed]
        case .battery: return [.batteryCharge]
        case .music:
            return (audioPermission == .granted ? [] : [.musicPermission]) + [.musicIntensity, .musicStrobe]
        case .agents: return [.agentsConnection, .agentsLive]
        }
    }
}

// MARK: - Menu bar icon state

package enum MenuBarIconState: Equatable {
    /// Filled dot: logo on.
    case on
    /// Ring: logo off.
    case off
    /// Dot with a small wave: an animated mode is running.
    case animated

    package init(status: EngineStatus) {
        if !status.isOn {
            self = .off
        } else if status.mode.isAnimated && status.pausedReason == nil {
            self = .animated
        } else {
            self = .on
        }
    }

    package var accessibilityDescription: String {
        switch self {
        case .on: return "Lidlight, logo on"
        case .off: return "Lidlight, logo off"
        case .animated: return "Lidlight, logo animating"
        }
    }
}

// MARK: - Quit flow

package enum QuitFlow {
    package enum Decision: Equatable {
        /// The logo is off: ask whether to keep it off.
        case askKeepOff
        case quit(keepOff: Bool)
    }

    package static func decision(logoIsOn: Bool) -> Decision {
        logoIsOn ? .quit(keepOff: false) : .askKeepOff
    }
}

// MARK: - Menu bar icon drawing

package enum MenuBarIcon {
    private static let side: CGFloat = 18

    /// 18 pt template image, drawn at the display's scale so it stays crisp at @2x.
    package static func image(for state: MenuBarIconState) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.set()
            switch state {
            case .on:
                NSBezierPath(ovalIn: NSRect(x: 4.5, y: 4.5, width: 9, height: 9)).fill()
            case .off:
                let ring = NSBezierPath(ovalIn: NSRect(x: 4.75, y: 4.75, width: 8.5, height: 8.5))
                ring.lineWidth = 1.5
                ring.stroke()
            case .animated:
                let center = NSPoint(x: 6.5, y: 9)
                NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
                for radius: CGFloat in [5.6, 8.2] {
                    let wave = NSBezierPath()
                    wave.appendArc(withCenter: center, radius: radius, startAngle: -38, endAngle: 38)
                    wave.lineWidth = 1.4
                    wave.lineCapStyle = .round
                    wave.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityDescription
        return image
    }
}
