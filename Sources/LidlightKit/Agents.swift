import Foundation

/// What Claude Code is doing, aggregated over all sessions.
/// Priority when several sessions disagree: needsYou > working > waiting > none.
public enum AgentActivity: String, Sendable, Codable, CaseIterable {
    /// No live Claude Code sessions.
    case none
    /// A session is open and idle, waiting for a prompt (soft glow).
    case waiting
    /// Claude is working on a prompt (steady pulse).
    case working
    /// Claude is blocked on a permission prompt or question (double blinks when you're away).
    case needsYou

    public var title: String {
        switch self {
        case .none: return "No sessions"
        case .waiting: return "Waiting"
        case .working: return "Working"
        case .needsYou: return "Needs you"
        }
    }
}

/// Aggregated agent state for the engine and UI.
public struct AgentSnapshot: Sendable, Equatable {
    public var activity: AgentActivity = .none
    public var sessions: Int = 0
    public var working: Int = 0
    public var needingYou: Int = 0
    public var updatedAt: Date = .distantPast

    public init() {}

    public init(activity: AgentActivity, sessions: Int, working: Int, needingYou: Int, updatedAt: Date) {
        self.activity = activity
        self.sessions = sessions
        self.working = working
        self.needingYou = needingYou
        self.updatedAt = updatedAt
    }
}

/// One file per Claude Code session in `AppPaths.agentsSpoolDirectory`, written by
/// `lidlightctl agent-event` (a Claude Code hook) and read by `AgentMonitor`.
/// File name: `<sanitized session id>.json`.
public struct AgentSessionRecord: Codable, Sendable, Equatable {
    public var sessionID: String
    public var activity: AgentActivity
    /// The hook event that produced this record (e.g. "UserPromptSubmit").
    public var lastEvent: String
    public var updatedAt: Date
    public var cwd: String?

    public init(sessionID: String, activity: AgentActivity, lastEvent: String, updatedAt: Date, cwd: String?) {
        self.sessionID = sessionID
        self.activity = activity
        self.lastEvent = lastEvent
        self.updatedAt = updatedAt
        self.cwd = cwd
    }
}

/// Observes agent session records (module LidlightAgents, class `AgentMonitor`).
public protocol AgentMonitoring: AnyObject {
    var snapshot: AgentSnapshot { get }
    /// Start observing. `onChange` runs on the main thread.
    func start(onChange: @escaping (AgentSnapshot) -> Void)
    func stop()
}

public enum HooksStatus: Sendable, Equatable {
    case notInstalled
    case installed
    /// Installed, but pointing at a different helper path or an older hook set.
    case needsUpdate
    case error(String)
}

/// Adds/removes Lidlight's hooks in Claude Code's user settings
/// (module LidlightAgents, class `ClaudeHooksInstaller`).
public protocol ClaudeHooksManaging: AnyObject {
    func status() -> HooksStatus
    /// Install (or update) hooks that run `<helperPath> agent-event`.
    func connect(helperPath: String) throws
    /// Remove only Lidlight's hooks; leave everything else untouched.
    func disconnect() throws
}
