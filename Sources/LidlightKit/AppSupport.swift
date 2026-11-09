import Foundation
import os

public enum AppInfo {
    public static let name = "Lidlight"
    public static let bundleID = "app.lidlight.Lidlight"
    /// The helper CLI bundled at `Lidlight.app/Contents/Helpers/lidlightctl`.
    public static let helperExecutableName = "lidlightctl"
    /// Darwin notification (notify(3)) posted by the hook helper after it writes a session record.
    public static let agentsChangedNotification = "app.lidlight.agents.changed"
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Persisted user settings (stored by the UI in UserDefaults as JSON).
public struct AppSettings: Codable, Sendable, Equatable {
    public var isOn: Bool = true
    public var mode: LogoMode = .steady
    public var effects = EffectSettings()
    public var openAtLogin: Bool = false
    /// Global shortcut control-command-B toggles the logo.
    public var globalShortcutEnabled: Bool = true
    public var agentsConnected: Bool = false

    public init() {}
}

public enum AppPaths {
    /// ~/Library/Application Support/Lidlight
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(AppInfo.name, isDirectory: true)
    }

    /// One JSON file per Claude Code session (see `AgentSessionRecord`).
    public static var agentsSpoolDirectory: URL {
        supportDirectory.appendingPathComponent("agents", isDirectory: true)
    }

    /// Present while Lidlight has changed corebrightnessd settings that must be restored
    /// (tables, overrides, power). Written by the driver, removed after a clean restore.
    public static var dirtyMarkerURL: URL {
        supportDirectory.appendingPathComponent("logo-modified.json")
    }

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: agentsSpoolDirectory, withIntermediateDirectories: true)
    }
}

public enum Log {
    public static let driver = Logger(subsystem: AppInfo.bundleID, category: "driver")
    public static let engine = Logger(subsystem: AppInfo.bundleID, category: "engine")
    public static let system = Logger(subsystem: AppInfo.bundleID, category: "system")
    public static let agents = Logger(subsystem: AppInfo.bundleID, category: "agents")
    public static let audio = Logger(subsystem: AppInfo.bundleID, category: "audio")
    public static let ui = Logger(subsystem: AppInfo.bundleID, category: "ui")
}
