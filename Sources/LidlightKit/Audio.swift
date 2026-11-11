import Foundation

/// A detected beat in what the Mac is playing.
public struct BeatEvent: Sendable, Equatable {
    /// `ProcessInfo.processInfo.systemUptime` when the beat was detected.
    public var uptime: TimeInterval
    /// 0...1, relative to recent beats.
    public var strength: Double
    /// Notably stronger than recent beats (used for the optional strobe).
    public var isStrong: Bool

    public init(uptime: TimeInterval, strength: Double, isStrong: Bool) {
        self.uptime = uptime
        self.strength = strength
        self.isStrong = isStrong
    }
}

public enum AudioCapturePermission: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
    /// macOS too old for system-audio taps.
    case unsupported
}

/// Captures system output audio (never the microphone) and reports beats
/// (module LidlightAudio, class `SystemAudioBeatSource`).
public protocol BeatSource: AnyObject {
    var isRunning: Bool { get }
    var permission: AudioCapturePermission { get }
    /// Start capturing. The first start may trigger macOS's "System Audio Recording" prompt.
    /// Callbacks run on the main thread. `onLevel`, if given, is called ~30 times a second with the
    /// bass level 0...1.
    func start(onBeat: @escaping (BeatEvent) -> Void, onLevel: ((Double) -> Void)?) throws
    func stop()
}
