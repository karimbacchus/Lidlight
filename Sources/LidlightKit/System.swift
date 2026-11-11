import Foundation

/// Everything the engine needs to know about the Mac's state.
public struct SystemStatus: Sendable, Equatable {
    /// Built-in display asleep (or off). The logo is dark then and must not be animated.
    public var displayAsleep: Bool = false
    /// Screen locked (lock screen showing or session switched out).
    public var screenLocked: Bool = false
    public var lowPowerMode: Bool = false
    /// Lid (clamshell) closed.
    public var lidClosed: Bool = false
    public var onBattery: Bool = false
    /// Internal battery charge 0...100, nil when there is no battery.
    public var batteryPercent: Double? = nil
    public var isCharging: Bool = false
    /// Seconds since the last keyboard/mouse/trackpad input.
    public var userIdleSeconds: Double = 0
    /// Built-in keyboard backlight currently lit.
    public var keyboardBacklightLit: Bool = false

    public init() {}

    /// True when the logo can be animated at all (display awake and lid open).
    public var animationPossible: Bool { !displayAsleep && !lidClosed }
}

/// System state observer (module LidlightSystem, class `SystemMonitor`).
public protocol SystemMonitoring: AnyObject {
    var status: SystemStatus { get }
    /// Start observing. `onChange` runs on the main thread whenever a field changes.
    /// `userIdleSeconds` is refreshed about every 2 seconds.
    func start(onChange: @escaping (SystemStatus) -> Void)
    func stop()
}
