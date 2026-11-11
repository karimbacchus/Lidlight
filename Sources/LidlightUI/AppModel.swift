import AppKit
import Combine
import LidlightKit

/// The app's state and the glue between the UI and every service. Main thread only.
public final class AppModel: ObservableObject {
    public let driver: LogoDriving
    public let preview: LogoPreviewSource
    public let engine: LogoControlling
    public let system: SystemMonitoring
    public let agents: AgentMonitoring
    public let hooks: ClaudeHooksManaging
    public let beats: BeatSource
    /// Path of the bundled `lidlightctl` (used for Claude Code hooks).
    public let helperURL: URL

    /// Persisted user settings. Change them through the setter methods so services follow.
    @Published public private(set) var settings: AppSettings
    @Published public private(set) var engineStatus: EngineStatus
    @Published public private(set) var systemStatus = SystemStatus()
    @Published public private(set) var agentSnapshot = AgentSnapshot()
    /// Live logo readout; refreshed at 2 Hz only while the popover is open.
    @Published public private(set) var logoState: LogoState?
    @Published public private(set) var hooksStatus: HooksStatus = .notInstalled
    @Published public private(set) var audioPermission: AudioCapturePermission = .notDetermined
    /// Why Claude Code hooks could not be changed, if they could not.
    @Published public private(set) var hooksError: String?
    /// Why the login item could not be changed, if it could not.
    @Published public private(set) var loginItemError: String?
    /// Whether the preview window is wanted (persisted separately from `AppSettings`).
    @Published public private(set) var showsPreviewWindow: Bool

    private let defaults: UserDefaults
    private let loginItem: LoginItemControlling
    private let pollQueue = DispatchQueue(label: "app.lidlight.ui.readout", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private var started = false

    package static let settingsKey = "settings.v1"
    package static let previewKey = "previewWindow.visible"

    public convenience init(
        driver: LogoDriving,
        preview: LogoPreviewSource,
        engine: LogoControlling,
        system: SystemMonitoring,
        agents: AgentMonitoring,
        hooks: ClaudeHooksManaging,
        beats: BeatSource,
        helperURL: URL
    ) {
        self.init(
            driver: driver, preview: preview, engine: engine, system: system, agents: agents,
            hooks: hooks, beats: beats, helperURL: helperURL,
            defaults: .standard, loginItem: SystemLoginItem()
        )
    }

    /// Designated initializer with injectable persistence and login item (used by checks and the demo).
    package init(
        driver: LogoDriving,
        preview: LogoPreviewSource,
        engine: LogoControlling,
        system: SystemMonitoring,
        agents: AgentMonitoring,
        hooks: ClaudeHooksManaging,
        beats: BeatSource,
        helperURL: URL,
        defaults: UserDefaults,
        loginItem: LoginItemControlling
    ) {
        self.driver = driver
        self.preview = preview
        self.engine = engine
        self.system = system
        self.agents = agents
        self.hooks = hooks
        self.beats = beats
        self.helperURL = helperURL
        self.defaults = defaults
        self.loginItem = loginItem
        let loaded = Self.loadSettings(from: defaults)
        self.settings = loaded
        self.engineStatus = EngineStatus(isOn: loaded.isOn, mode: loaded.mode)
        self.showsPreviewWindow = defaults.bool(forKey: Self.previewKey)
    }

    // MARK: Persistence

    package static func loadSettings(from defaults: UserDefaults) -> AppSettings {
        guard let data = defaults.data(forKey: settingsKey) else { return AppSettings() }
        do {
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            settings.effects = settings.effects.sanitized()
            return settings
        } catch {
            Log.ui.error("Ignoring unreadable settings: \(error.localizedDescription)")
            return AppSettings()
        }
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Self.settingsKey)
        } catch {
            Log.ui.error("Could not save settings: \(error.localizedDescription)")
        }
    }

    private func mutate(_ change: (inout AppSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        settings = updated
        persist()
    }

    private func mutateEffects(_ change: (inout EffectSettings) -> Void) {
        mutate { change(&$0.effects) }
        engine.setSettings(settings.effects)
    }

    // MARK: Lifecycle

    /// Applies the persisted settings to every service and starts observing them.
    public func start() {
        guard !started else { return }
        started = true
        engine.onStatusChange = { [weak self] status in self?.engineStatus = status }
        engine.start(isOn: settings.isOn, mode: settings.mode, settings: settings.effects)
        engineStatus = engine.status
        system.start { [weak self] status in
            guard let self else { return }
            systemStatus = status
            engine.update(system: status)
        }
        systemStatus = system.status
        engine.update(system: system.status)
        agents.start { [weak self] snapshot in
            guard let self else { return }
            agentSnapshot = snapshot
            engine.update(agents: snapshot)
        }
        agentSnapshot = agents.snapshot
        engine.update(agents: agents.snapshot)
        syncBeatSource()
        refreshHooks()
        refreshLoginItem()
        if settings.agentsConnected, hooksStatus == .needsUpdate { connectAgents() }
    }

    /// Stops every service. Called from the quit flow.
    package func finishQuit(keepOff: Bool) {
        stopReadoutPolling()
        if !keepOff, !settings.isOn { mutate { $0.isOn = true } }
        engine.shutdown(restoreDefaults: true, keepOff: keepOff)
        system.stop()
        agents.stop()
        beats.stop()
    }

    // MARK: Logo controls

    public func setOn(_ on: Bool) {
        mutate { $0.isOn = on }
        engine.setOn(on)
    }

    public func toggleOn() { setOn(!settings.isOn) }

    public func setMode(_ mode: LogoMode) {
        mutate { $0.mode = mode }
        engine.setMode(mode)
        syncBeatSource()
    }

    public func setBrightness(_ slider: Double) { mutateEffects { $0.brightness = min(max(slider, 0), 1) } }
    public func setBreathePeriod(_ seconds: Double) { mutateEffects { $0.breathePeriod = seconds } }
    public func setMusicIntensity(_ value: Double) { mutateEffects { $0.musicIntensity = value } }
    public func setMusicStrobe(_ on: Bool) { mutateEffects { $0.musicStrobe = on } }
    public func setFullBrightnessInAnyRoom(_ on: Bool) { mutateEffects { $0.fullBrightnessInAnyRoom = on } }
    public func setPauseWhileKeyboardLit(_ on: Bool) { mutateEffects { $0.pauseWhileKeyboardLit = on } }
    public func setAgentAwayAfter(_ seconds: Double) { mutateEffects { $0.agentAwayAfter = seconds } }

    public func setGlobalShortcutEnabled(_ on: Bool) { mutate { $0.globalShortcutEnabled = on } }

    public func setShowsPreviewWindow(_ show: Bool) {
        guard show != showsPreviewWindow else { return }
        showsPreviewWindow = show
        defaults.set(show, forKey: Self.previewKey)
    }

    /// Settings "Test" buttons.
    public func previewAgents(_ activity: AgentActivity) { engine.preview(activity) }

    /// Hands the logo back to macOS: quits with the logo on and Apple's settings restored.
    /// (Restoring while Lidlight keeps running would leave the engine and the logo out of sync.)
    public func restoreAppleLogoSettingsAndQuit() {
        quitRestoringAppleSettings = true
        NSApp.terminate(nil)
    }

    /// Set by `restoreAppleLogoSettingsAndQuit`; the quit flow then skips the keep-off question.
    package private(set) var quitRestoringAppleSettings = false

    // MARK: Login item

    public func setOpenAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            Log.ui.error("Login item change failed: \(error.localizedDescription)")
            loginItemError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        mutate { $0.openAtLogin = loginItem.isEnabled }
    }

    /// Re-reads the login item's real state (the user may change it in System Settings).
    public func refreshLoginItem() {
        mutate { $0.openAtLogin = loginItem.isEnabled }
    }

    // MARK: Claude Code hooks

    public func refreshHooks() { hooksStatus = hooks.status() }

    public func connectAgents() {
        do {
            try hooks.connect(helperPath: helperURL.path)
            hooksError = nil
            mutate { $0.agentsConnected = true }
        } catch {
            Log.ui.error("Connecting Claude Code failed: \(error.localizedDescription)")
            hooksError = "Couldn't connect: \(error.localizedDescription)"
        }
        refreshHooks()
    }

    public func disconnectAgents() {
        do {
            try hooks.disconnect()
            hooksError = nil
            mutate { $0.agentsConnected = false }
        } catch {
            Log.ui.error("Disconnecting Claude Code failed: \(error.localizedDescription)")
            hooksError = "Couldn't disconnect: \(error.localizedDescription)"
        }
        refreshHooks()
    }

    // MARK: Music

    /// Starts the beat source only while Music is the mode.
    private func syncBeatSource() {
        if settings.mode == .music {
            if !beats.isRunning { startBeatSource() }
        } else if beats.isRunning {
            beats.stop()
        }
        audioPermission = beats.permission
    }

    private func startBeatSource() {
        do {
            try beats.start(onBeat: { [weak self] beat in self?.engine.handleBeat(beat) }, onLevel: nil)
        } catch {
            Log.ui.error("Audio capture failed to start: \(error.localizedDescription)")
        }
    }

    /// Re-checks audio permission and retries a failed start (the user may have just granted it).
    public func refreshAudioAccess() { syncBeatSource() }

    public func openAudioPrivacySettings() {
        NSWorkspace.shared.open(AppInfo.audioPrivacySettingsURL)
    }

    // MARK: Live readout

    /// Polls the logo at 2 Hz while the popover is open.
    public func setPopoverVisible(_ visible: Bool) {
        visible ? startReadoutPolling() : stopReadoutPolling()
    }

    private func startReadoutPolling() {
        guard pollTimer == nil else { return }
        refreshHooks()
        syncBeatSource()
        let driver = driver
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            let state = driver.readState()
            DispatchQueue.main.async { self?.logoState = state }
        }
        pollTimer = timer
        timer.resume()
    }

    private func stopReadoutPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }
}
