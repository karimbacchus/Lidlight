import Foundation
import LidlightKit

/// Written (to `AppPaths.dirtyMarkerURL`) before the first write that modifies corebrightnessd and
/// removed after a clean restore. If a marker outlives its process, the guardian or the next
/// launch restores Apple's settings.
package struct DirtyMarker: Codable, Equatable {
    package var pid: Int32
    package var since: Date
    package var tablesModified: Bool
    package var factorModified: Bool

    package init(pid: Int32, since: Date, tablesModified: Bool, factorModified: Bool) {
        self.pid = pid
        self.since = since
        self.tablesModified = tablesModified
        self.factorModified = factorModified
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The marker at `url`, or nil if absent or unreadable.
    package static func read(from url: URL) -> DirtyMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(DirtyMarker.self, from: data)
    }

    package func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    package static func remove(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// True if the process that wrote this marker is still running.
    package var ownerIsAlive: Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
