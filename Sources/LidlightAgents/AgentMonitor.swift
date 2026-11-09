import Foundation
import notify
import LidlightKit

/// Watches `AppPaths.agentsSpoolDirectory` and aggregates Claude Code sessions.
public final class AgentMonitor: AgentMonitoring {
    /// A "working" session with no event for this long is treated as waiting.
    package static let staleWorkingInterval: TimeInterval = 10 * 60
    /// Records older than this are deleted.
    package static let expiryInterval: TimeInterval = 12 * 60 * 60
    private static let sweepInterval: TimeInterval = 5

    public private(set) var snapshot = AgentSnapshot()

    private let spoolDirectory: URL
    private let now: () -> Date
    private var onChange: ((AgentSnapshot) -> Void)?
    private var notifyToken: Int32 = 0
    private var isRegistered = false
    private var timer: DispatchSourceTimer?

    public convenience init(spoolDirectory: URL = AppPaths.agentsSpoolDirectory) {
        self.init(spoolDirectory: spoolDirectory, now: Date.init)
    }

    /// Checks inject a clock; they drive `refresh()` directly instead of relying on timers.
    package init(spoolDirectory: URL, now: @escaping () -> Date) {
        self.spoolDirectory = spoolDirectory
        self.now = now
    }

    deinit { stop() }

    /// Starts observing and delivers the current snapshot immediately. Call on the main thread.
    public func start(onChange: @escaping (AgentSnapshot) -> Void) {
        stop()
        self.onChange = onChange
        try? FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)

        let status = notify_register_dispatch(AppInfo.agentsChangedNotification, &notifyToken, .main) {
            [weak self] _ in self?.refresh()
        }
        if status == UInt32(NOTIFY_STATUS_OK) {
            isRegistered = true
        } else {
            Log.agents.error("notify_register_dispatch failed: \(status)")
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.sweepInterval, repeating: Self.sweepInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer

        let initial = aggregate()
        snapshot = initial
        onChange(initial)
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        if isRegistered {
            notify_cancel(notifyToken)
            isRegistered = false
        }
        onChange = nil
    }

    /// Re-reads the spool and publishes if the aggregate changed.
    package func refresh() {
        let latest = aggregate()
        let changed = !latest.isEquivalent(to: snapshot)
        snapshot = latest
        if changed { onChange?(latest) }
    }

    private func aggregate() -> AgentSnapshot {
        let current = now()
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: spoolDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = AgentRecordStore.makeDecoder()

        var sessions = 0, working = 0, needingYou = 0
        var newest = Date.distantPast
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(AgentSessionRecord.self, from: data) else { continue }
            let age = current.timeIntervalSince(record.updatedAt)
            if age > Self.expiryInterval {
                try? fm.removeItem(at: file)
                continue
            }
            sessions += 1
            newest = max(newest, record.updatedAt)
            switch record.activity {
            case .needsYou: needingYou += 1
            case .working where age <= Self.staleWorkingInterval: working += 1
            case .working, .waiting, .none: break
            }
        }
        let activity: AgentActivity =
            needingYou > 0 ? .needsYou : working > 0 ? .working : sessions > 0 ? .waiting : .none
        return AgentSnapshot(activity: activity, sessions: sessions, working: working,
                             needingYou: needingYou, updatedAt: newest)
    }
}

private extension AgentSnapshot {
    /// Equality ignoring `updatedAt`, so routine events inside one state don't republish.
    func isEquivalent(to other: AgentSnapshot) -> Bool {
        activity == other.activity && sessions == other.sessions
            && working == other.working && needingYou == other.needingYou
    }
}
