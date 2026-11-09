import CryptoKit
import Foundation
import LidlightKit

/// Claude Code hook events Lidlight listens to and what each one means for the logo.
package enum AgentHookEvent: String, CaseIterable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case subagentStop = "SubagentStop"
    case notification = "Notification"
    case permissionRequest = "PermissionRequest"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"

    /// The activity a session is in after this event; `nil` means the session ended.
    package var activity: AgentActivity? {
        switch self {
        case .sessionStart, .stop: return .waiting
        case .userPromptSubmit, .preToolUse, .postToolUse, .subagentStop: return .working
        case .notification, .permissionRequest: return .needsYou
        case .sessionEnd: return nil
        }
    }

    /// Whether Claude Code accepts a `matcher` for this event's hook group.
    package var supportsMatcher: Bool {
        switch self {
        case .userPromptSubmit, .stop: return false
        default: return true
        }
    }
}

/// Shared JSON coding and file naming for session records.
package enum AgentRecordStore {
    package static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    package static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A safe file name stem for a session id: the id itself when it only uses
    /// `[A-Za-z0-9._-]`, is at most 80 characters and does not start with a dot;
    /// otherwise `h-` followed by a SHA-256 prefix of the id.
    package static func fileStem(forSessionID id: String) -> String {
        let allowed = id.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
        if allowed, !id.isEmpty, id.utf8.count <= 80, !id.hasPrefix(".") { return id }
        let digest = SHA256.hash(data: Data(id.utf8))
        return "h-" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}
