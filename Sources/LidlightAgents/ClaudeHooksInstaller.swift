import Foundation
import LidlightKit

/// Why the settings file could not be changed.
public enum ClaudeHooksError: LocalizedError {
    case invalidSettings(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSettings(let reason): return "Claude Code settings can't be edited safely: \(reason)"
        }
    }
}

/// Adds/removes Lidlight's hooks in Claude Code's user settings file.
public final class ClaudeHooksInstaller: ClaudeHooksManaging {
    private static let hookTimeoutSeconds = 5
    private static let backupSuffix = ".lidlight-backup"

    private let settingsURL: URL
    /// The helper path `status()` expects. Set by `connect(helperPath:)`, or up front by the
    /// app. While `nil`, `status()` accepts any helper path as long as every event agrees.
    public var expectedHelperPath: String?

    /// Default: `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`.
    public init(settingsURL: URL? = nil, expectedHelperPath: String? = nil) {
        self.settingsURL = settingsURL ?? Self.defaultSettingsURL()
        self.expectedHelperPath = expectedHelperPath
    }

    private static func defaultSettingsURL() -> URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("settings.json")
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude/settings.json")
    }

    // MARK: ClaudeHooksManaging

    public func status() -> HooksStatus {
        let root: [String: Any]
        do { root = try loadSettings() ?? [:] } catch { return .error(error.localizedDescription) }
        let hooks = root["hooks"] as? [String: Any] ?? [:]

        var commands = Set<String>()
        var missing = 0
        for event in AgentHookEvent.allCases {
            let found = Self.ourCommands(in: hooks[event.rawValue])
            if found.isEmpty { missing += 1 }
            commands.formUnion(found)
        }
        if commands.isEmpty { return .notInstalled }
        if missing > 0 || commands.count > 1 { return .needsUpdate }
        if let path = expectedHelperPath, commands.first != Self.command(forHelper: path) { return .needsUpdate }
        return .installed
    }

    public func connect(helperPath: String) throws {
        expectedHelperPath = helperPath
        if status() == .installed { return }
        let original = try loadSettings()
        var root = original ?? [:]
        var hooks = try hooksObject(of: root)
        let command = Self.command(forHelper: helperPath)

        for event in AgentHookEvent.allCases {
            var groups = try Self.groups(in: hooks[event.rawValue], event: event.rawValue)
            Self.removeOurs(from: &groups)
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": command, "timeout": Self.hookTimeoutSeconds]],
            ]
            if event.supportsMatcher { group["matcher"] = "*" }
            groups.append(group)
            hooks[event.rawValue] = groups
        }
        root["hooks"] = hooks
        try save(root, replacing: original)
    }

    public func disconnect() throws {
        guard let original = try loadSettings() else { return }
        var root = original
        var hooks = try hooksObject(of: root)
        var changed = false

        for (name, value) in hooks {
            var groups = try Self.groups(in: value, event: name)
            let hadOurs = !Self.ourCommands(in: value).isEmpty
            guard hadOurs else { continue }
            changed = true
            Self.removeOurs(from: &groups)
            hooks[name] = groups.isEmpty ? nil : groups
        }
        guard changed else { return }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try save(root, replacing: original)
    }

    // MARK: Hook entries

    /// `'<helper>' agent-event`, with the path single-quoted for the shell.
    private static func command(forHelper path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' agent-event"
    }

    private static func isOurs(_ handler: [String: Any]) -> Bool {
        guard let command = handler["command"] as? String else { return false }
        return command.contains("lidlightctl") && command.contains("agent-event")
    }

    private static func ourCommands(in eventValue: Any?) -> [String] {
        let groups = eventValue as? [[String: Any]] ?? []
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).filter(isOurs).compactMap { $0["command"] as? String }
        }
    }

    private static func groups(in value: Any?, event: String) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let groups = value as? [[String: Any]] else {
            throw ClaudeHooksError.invalidSettings("hooks.\(event) is not a list of hook groups")
        }
        return groups
    }

    /// Removes our handlers, then any group that our removal left without handlers.
    private static func removeOurs(from groups: inout [[String: Any]]) {
        groups = groups.compactMap { group in
            guard let handlers = group["hooks"] as? [[String: Any]], handlers.contains(where: isOurs) else {
                return group
            }
            let remaining = handlers.filter { !isOurs($0) }
            if remaining.isEmpty { return nil }
            var copy = group
            copy["hooks"] = remaining
            return copy
        }
    }

    private func hooksObject(of root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw ClaudeHooksError.invalidSettings("\"hooks\" is not an object")
        }
        return hooks
    }

    // MARK: File access

    /// The parsed settings object, or `nil` if the file doesn't exist. Throws for anything unreadable.
    private func loadSettings() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let data = try Data(contentsOf: settingsURL)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeHooksError.invalidSettings("\(settingsURL.lastPathComponent) is not a valid JSON object")
        }
        return object
    }

    private func save(_ root: [String: Any], replacing original: [String: Any]?) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if original != nil {
            let backup = URL(fileURLWithPath: settingsURL.path + Self.backupSuffix)
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        try data.write(to: settingsURL, options: .atomic)
        Log.agents.info("Updated Claude Code hooks in \(self.settingsURL.path, privacy: .public)")
    }
}
