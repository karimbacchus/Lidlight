import AppKit
import Foundation
import LidlightKit

/// Captures system output audio with a Core Audio process tap and reports beats (never the microphone).
public final class SystemAudioBeatSource: BeatSource {
    private let lock = NSLock()
    private var session: Any?  // AudioCaptureSession (macOS 14.2+)
    private var callbacks: (onBeat: (BeatEvent) -> Void, onLevel: (Double) -> Void)?
    private var storedPermission: AudioCapturePermission
    private var restartGeneration = 0
    private let controlQueue = DispatchQueue(label: "app.lidlight.audio.control", qos: .utility)

    private static let restartDelay: TimeInterval = 0.4
    private static let restartRetries = 5

    public init() {
        if #available(macOS 14.2, *) {
            storedPermission = .notDetermined
        } else {
            storedPermission = .unsupported
        }
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return session != nil
    }

    public var permission: AudioCapturePermission {
        lock.lock(); defer { lock.unlock() }
        return storedPermission
    }

    /// Starts capturing. Throws `AudioCaptureError`; `.denied`/`.unsupported` are also reflected in `permission`.
    public func start(onBeat: @escaping (BeatEvent) -> Void, onLevel: @escaping (Double) -> Void) throws {
        guard #available(macOS 14.2, *) else { throw AudioCaptureError.unsupported }
        lock.lock(); defer { lock.unlock() }
        guard session == nil else { return }
        callbacks = (onBeat, onLevel)
        do {
            try startSessionLocked()
        } catch {
            callbacks = nil
            throw error
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        restartGeneration += 1
        callbacks = nil
        stopSessionLocked()
    }

    /// Opens System Settings › Privacy & Security › Screen & System Audio Recording.
    public static func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
        Log.audio.error("Could not open the Privacy & Security settings pane")
    }

    // MARK: Session management (lock held)

    @available(macOS 14.2, *)
    private func startSessionLocked() throws {
        guard let callbacks else { return }
        let generation = restartGeneration
        let newSession = AudioCaptureSession()
        do {
            try newSession.start(
                onBeat: callbacks.onBeat,
                onLevel: callbacks.onLevel,
                onConfigurationChange: { [weak self] in self?.scheduleRestart(after: generation) }
            )
        } catch AudioCaptureError.denied {
            storedPermission = .denied
            Log.audio.error("System audio capture denied")
            throw AudioCaptureError.denied
        } catch {
            Log.audio.error("System audio capture failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        session = newSession
        storedPermission = .granted
        Log.audio.info("System audio capture started")
    }

    private func stopSessionLocked() {
        guard #available(macOS 14.2, *), let current = session as? AudioCaptureSession else { return }
        current.stop()
        session = nil
        Log.audio.info("System audio capture stopped")
    }

    /// The default output device or tap format changed: rebuild the capture graph after a short settle delay.
    private func scheduleRestart(after generation: Int) {
        controlQueue.asyncAfter(deadline: .now() + Self.restartDelay) { [weak self] in
            self?.restart(generation: generation, retriesLeft: Self.restartRetries)
        }
    }

    private func restart(generation: Int, retriesLeft: Int) {
        guard #available(macOS 14.2, *) else { return }
        lock.lock()
        defer { lock.unlock() }
        // Stale: stopped (or restarted) since this change was observed.
        guard generation == restartGeneration, callbacks != nil else { return }
        restartGeneration += 1
        let next = restartGeneration
        stopSessionLocked()
        do {
            try startSessionLocked()
        } catch {
            guard retriesLeft > 0 else {
                Log.audio.error("Giving up restarting audio capture")
                callbacks = nil
                return
            }
            controlQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.restart(generation: next, retriesLeft: retriesLeft - 1)
            }
        }
    }
}
