import Foundation

/// The logo's behavior, picked in the menu.
public enum LogoMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case steady
    case breathe
    case battery
    case music
    case agents

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .steady: return "Steady"
        case .breathe: return "Breathe"
        case .battery: return "Battery"
        case .music: return "Music"
        case .agents: return "Agents"
        }
    }

    public var subtitle: String {
        switch self {
        case .steady: return "A constant glow at the brightness you set."
        case .breathe: return "Fades in and out, like a sleep light."
        case .battery: return "Dims as your charge runs down."
        case .music: return "Pulses to the beat of what your Mac plays."
        case .agents: return "Shows what Claude Code is doing."
        }
    }

    /// SF Symbol for menus.
    public var symbolName: String {
        switch self {
        case .steady: return "circle.fill"
        case .breathe: return "wind"
        case .battery: return "battery.75percent"
        case .music: return "music.note"
        case .agents: return "sparkles"
        }
    }

    /// True for modes that animate the logo (drives the "dot with a wave" menu bar icon).
    public var isAnimated: Bool {
        switch self {
        case .steady, .battery: return false
        case .breathe, .music, .agents: return true
        }
    }
}

/// User-tunable effect parameters.
public struct EffectSettings: Sendable, Equatable, Codable {
    /// Brightness slider position 0...1 (perceptual; the engine maps it to nits).
    public var brightness: Double = 0.8
    /// Seconds per breath, 3...10.
    public var breathePeriod: Double = 6
    /// How hard Music hits, 0...1.
    public var musicIntensity: Double = 0.7
    /// Extra flashes on strong beats (always capped at 3 flashes per second).
    public var musicStrobe: Bool = false
    /// Lift Apple's dark-room cap (max-restriction table → flat 1000 nits).
    public var fullBrightnessInAnyRoom: Bool = false
    /// Pause animations while the built-in keyboard backlight is lit. Off by default: the driver
    /// restores the keyboard backlight after every dark phase, so this is only a fallback.
    public var pauseWhileKeyboardLit: Bool = false
    /// Seconds without keyboard/mouse input before "needs you" blinks start.
    public var agentAwayAfter: Double = 30

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case brightness, breathePeriod, musicIntensity, musicStrobe, fullBrightnessInAnyRoom
        // Renamed from "pauseWhileKeyboardLit" (default on in 0.1.0) so the new default applies.
        case pauseWhileKeyboardLit = "pauseForKeyboardBacklight"
        case agentAwayAfter
    }

    /// Missing keys keep their defaults, so settings saved by an older version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? brightness
        breathePeriod = try c.decodeIfPresent(Double.self, forKey: .breathePeriod) ?? breathePeriod
        musicIntensity = try c.decodeIfPresent(Double.self, forKey: .musicIntensity) ?? musicIntensity
        musicStrobe = try c.decodeIfPresent(Bool.self, forKey: .musicStrobe) ?? musicStrobe
        fullBrightnessInAnyRoom = try c.decodeIfPresent(Bool.self, forKey: .fullBrightnessInAnyRoom) ?? fullBrightnessInAnyRoom
        pauseWhileKeyboardLit = try c.decodeIfPresent(Bool.self, forKey: .pauseWhileKeyboardLit) ?? pauseWhileKeyboardLit
        agentAwayAfter = try c.decodeIfPresent(Double.self, forKey: .agentAwayAfter) ?? agentAwayAfter
    }

    public static let breathePeriodRange: ClosedRange<Double> = 3...10
}

/// Why the engine is not animating right now.
public enum PauseReason: String, Sendable, Equatable, Codable {
    case logoOff
    case displayAsleep
    case lidClosed
    case screenLocked
    case lowPowerMode
    case keyboardLit
    case unsupported
}

/// Snapshot of what the engine is doing, for the UI.
public struct EngineStatus: Sendable, Equatable {
    public var isOn: Bool
    public var mode: LogoMode
    /// True while an effect is actively driving the factor channel.
    public var isAnimating: Bool
    public var pausedReason: PauseReason?
    /// The steady level (nits) the engine asked corebrightnessd for.
    public var targetNits: Double
    /// Agent activity currently being shown (Agents mode only).
    public var shownActivity: AgentActivity

    public init(
        isOn: Bool = true,
        mode: LogoMode = .steady,
        isAnimating: Bool = false,
        pausedReason: PauseReason? = nil,
        targetNits: Double = 0,
        shownActivity: AgentActivity = .none
    ) {
        self.isOn = isOn
        self.mode = mode
        self.isAnimating = isAnimating
        self.pausedReason = pausedReason
        self.targetNits = targetNits
        self.shownActivity = shownActivity
    }
}

/// The effect engine (module LidlightEngine, class `EffectEngine`).
///
/// All methods must be called on the main thread; callbacks are delivered on the main thread.
/// The engine owns every write to the driver except reads for UI readouts.
public protocol LogoControlling: AnyObject {
    var status: EngineStatus { get }
    var onStatusChange: ((EngineStatus) -> Void)? { get set }

    /// Begin driving the logo with the persisted settings.
    func start(isOn: Bool, mode: LogoMode, settings: EffectSettings)
    /// User on/off switch. Writes LEBacklightMode (rate-limited).
    func setOn(_ on: Bool)
    func setMode(_ mode: LogoMode)
    func setSettings(_ settings: EffectSettings)

    func update(system: SystemStatus)
    func update(agents: AgentSnapshot)
    func handleBeat(_ beat: BeatEvent)
    /// Continuous bass level 0...1 between beats (Music mode).
    func handleAudioLevel(_ level: Double)

    /// Show an Agents pattern for a few seconds regardless of mode (Settings "Test" buttons).
    func preview(_ activity: AgentActivity)

    /// Stop all effects before quitting.
    /// - restoreDefaults: put Apple's tables back and clear overrides.
    /// - keepOff: leave LEBacklightMode at off (user chose to keep the logo off after quitting);
    ///   otherwise power is set back to on.
    func shutdown(restoreDefaults: Bool, keepOff: Bool)
}
