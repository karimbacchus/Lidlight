import Foundation
import notify
import LidlightKit

/// `lidlightctl agent-event`: run by Claude Code hooks. Reads the hook JSON from stdin,
/// writes the session record, posts the Darwin notification. Must print nothing to stdout,
/// finish fast, and always return 0 so it can never disrupt Claude Code.
public enum AgentHookCommand {
    private static let maxInputBytes = 1_048_576

    /// Handles one hook invocation. `arguments` are the arguments after `agent-event`;
    /// `--spool <dir>` overrides the spool directory. Always returns 0.
    public static func run(arguments: [String], stdin: FileHandle) -> Int32 {
        let input = readInput(stdin)
        guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let eventName = payload["hook_event_name"] as? String,
              let event = AgentHookEvent(rawValue: eventName),
              let sessionID = payload["session_id"] as? String, !sessionID.isEmpty
        else { return 0 }
        // Authentication notices are not about the session's activity.
        if event == .notification, payload["notification_type"] as? String == "auth_success" { return 0 }

        let spool = spoolDirectory(arguments)
        let file = spool.appendingPathComponent(AgentRecordStore.fileStem(forSessionID: sessionID) + ".json")
        do {
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
            if let activity = event.activity {
                let record = AgentSessionRecord(
                    sessionID: sessionID, activity: activity, lastEvent: eventName,
                    updatedAt: Date(), cwd: payload["cwd"] as? String)
                try write(record, to: file)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        } catch {
            return 0
        }
        notify_post(AppInfo.agentsChangedNotification)
        return 0
    }

    private static func spoolDirectory(_ arguments: [String]) -> URL {
        if let flag = arguments.firstIndex(of: "--spool"), flag + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        }
        return AppPaths.agentsSpoolDirectory
    }

    private static func readInput(_ handle: FileHandle) -> Data {
        var data = Data()
        while data.count < maxInputBytes {
            guard let chunk = try? handle.read(upToCount: min(65_536, maxInputBytes - data.count)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    /// Writes via a temporary file and `rename(2)` so the monitor never sees a partial record.
    private static func write(_ record: AgentSessionRecord, to file: URL) throws {
        let data = try AgentRecordStore.makeEncoder().encode(record)
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).\(getpid()).tmp")
        try data.write(to: temp)
        if rename(temp.path, file.path) != 0 {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
