import Foundation
import LidlightKit

/// Real hardware driver over CoreBrightness. `init?()` returns nil when this Mac has no
/// controllable logo (`LEBacklightMode` / `LEPWMState` unreadable).
///
/// All XPC runs on one serial queue. Rate limits (see docs/HARDWARE.md for why): power writes are
/// at least 1 s apart, each table key is written at most once per 2 s; a request that arrives too
/// early is deferred and the latest value wins. Anything that modifies corebrightnessd's tables
/// or the animation channel is preceded by a dirty marker (`DirtyMarker`) so a crash can be repaired.
public final class CoreBrightnessLogoDriver: LogoDriving, LogoPreviewSource, @unchecked Sendable {
    private struct TableSlot {
        /// Last value known to be in corebrightnessd (read or written).
        var known: NitsTable?
        /// Value waiting to be written.
        var desired: NitsTable?
        var lastWrite: TimeInterval = -.infinity
        var flush: DispatchWorkItem?
    }

    private let transport: LogoPropertyTransport
    private let markerURL: URL
    private let powerInterval: TimeInterval
    private let tableInterval: TimeInterval
    private let queue = DispatchQueue(label: "app.lidlight.driver")

    // Confined to `queue`.
    private var animationAllowed = true
    private var desiredPower: LogoPower?
    private var lastPowerWrite: TimeInterval = -.infinity
    private var powerFlush: DispatchWorkItem?
    private var slots: [String: TableSlot] = [:]
    private var lastFade: Double?
    /// True while a factor target we wrote may still be in effect.
    private var factorHeld = false
    private var marker: DirtyMarker?

    // Preview cache, guarded by `previewLock`.
    private let previewLock = NSLock()
    private var previewValue = 0.0
    private var previewRefreshedAt: TimeInterval = -.infinity
    private var previewRefreshing = false

    /// Minimum spacing between preview refreshes (10 Hz).
    private static let previewInterval: TimeInterval = 0.1

    public convenience init?() {
        guard let transport = BridgeTransport() else { return nil }
        self.init(transport: transport)
    }

    package init?(
        transport: LogoPropertyTransport,
        markerURL: URL = AppPaths.dirtyMarkerURL,
        powerInterval: TimeInterval = 1,
        tableInterval: TimeInterval = 2
    ) {
        guard transport.property(forKey: LogoKey.backlightMode) != nil,
              LogoState(propertyList: transport.property(forKey: LogoKey.state)) != nil else {
            return nil
        }
        self.transport = transport
        self.markerURL = markerURL
        self.powerInterval = powerInterval
        self.tableInterval = tableInterval
    }

    public var isSupported: Bool { true }
    public var isSimulated: Bool { false }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Reads

    public func readState() -> LogoState? {
        queue.sync { readStateLocked() }
    }

    public func readPower() -> LogoPower? {
        queue.sync { readPowerLocked() }
    }

    public func readTables() -> LogoTables? {
        queue.sync {
            guard let mapping = readTableLocked(LogoKey.mapping),
                  let minRestriction = readTableLocked(LogoKey.minRestriction),
                  let maxRestriction = readTableLocked(LogoKey.maxRestriction) else { return nil }
            return LogoTables(mapping: mapping, minRestriction: minRestriction, maxRestriction: maxRestriction)
        }
    }

    private func readStateLocked() -> LogoState? {
        LogoState(propertyList: transport.property(forKey: LogoKey.state))
    }

    private func readPowerLocked() -> LogoPower? {
        guard let raw = (transport.property(forKey: LogoKey.backlightMode) as? NSNumber)?.intValue else { return nil }
        return LogoPower(rawValue: raw)
    }

    private func readTableLocked(_ key: String) -> NitsTable? {
        transport.property(forKey: key).flatMap { NitsTable(propertyListValue: $0) }
    }

    // MARK: Power

    public func setPower(_ power: LogoPower) throws {
        try queue.sync {
            desiredPower = power
            try flushPower(waiting: false)
        }
    }

    /// Writes the desired power if it differs from the hardware and the rate limit allows;
    /// otherwise schedules itself for when it does. With `waiting`, blocks until allowed.
    private func flushPower(waiting: Bool) throws {
        powerFlush?.cancel()
        powerFlush = nil
        guard let desired = desiredPower else { return }
        if readPowerLocked() == desired {
            desiredPower = nil
            return
        }
        let wait = lastPowerWrite + powerInterval - Self.now
        if wait > 0 {
            if waiting {
                Thread.sleep(forTimeInterval: wait)
            } else {
                schedulePowerFlush(after: wait)
                return
            }
        }
        desiredPower = nil
        guard transport.setProperty(NSNumber(value: desired.rawValue), forKey: LogoKey.backlightMode) else {
            Log.driver.error("corebrightnessd rejected \(LogoKey.backlightMode, privacy: .public) = \(desired.rawValue)")
            throw LogoDriverError.writeFailed(key: LogoKey.backlightMode)
        }
        lastPowerWrite = Self.now
        Log.driver.info("logo power -> \(desired.rawValue)")
    }

    private func schedulePowerFlush(after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.powerFlush = nil
            do { try self.flushPower(waiting: false) } catch { Log.driver.error("deferred power write failed: \(error)") }
        }
        powerFlush = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: Tables

    public func writeTables(_ tables: LogoTables) throws {
        if let problem = tables.validationProblem { throw LogoDriverError.invalidTable(problem) }
        try queue.sync {
            for (key, table) in tables.keyedTables {
                slots[key, default: TableSlot()].desired = table
            }
            var firstError: Error?
            for (key, _) in tables.keyedTables {
                do { try flushTable(key, waiting: false) } catch { firstError = firstError ?? error }
            }
            if let firstError { throw firstError }
        }
    }

    private func flushTable(_ key: String, waiting: Bool) throws {
        guard var slot = slots[key] else { return }
        slot.flush?.cancel()
        slot.flush = nil
        defer { slots[key] = slot }
        guard let desired = slot.desired else { return }
        if slot.known == nil { slot.known = readTableLocked(key) }
        if let known = slot.known, known.isClose(to: desired) {
            slot.desired = nil
            return
        }
        let wait = slot.lastWrite + tableInterval - Self.now
        if wait > 0 {
            if waiting {
                Thread.sleep(forTimeInterval: wait)
            } else {
                slot.flush = makeTableFlush(key, after: wait)
                return
            }
        }
        slot.desired = nil
        try markModified(tables: true)
        guard transport.setProperty(desired.propertyListValue, forKey: key) else {
            slot.known = nil
            Log.driver.error("corebrightnessd rejected \(key, privacy: .public)")
            throw LogoDriverError.writeFailed(key: key)
        }
        slot.known = desired
        slot.lastWrite = Self.now
        Log.driver.info("wrote \(key, privacy: .public)")
    }

    private func makeTableFlush(_ key: String, after delay: TimeInterval) -> DispatchWorkItem {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.slots[key]?.flush = nil
            do { try self.flushTable(key, waiting: false) } catch { Log.driver.error("deferred table write failed: \(error)") }
        }
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    // MARK: Animation channel

    public func setAnimationAllowed(_ allowed: Bool) {
        queue.sync {
            guard allowed != animationAllowed else { return }
            animationAllowed = allowed
            guard !allowed else { return }
            // The system takes the factor over (display sleep / lid closed); only our override remains.
            factorHeld = false
            do { try writeFade(0) } catch { Log.driver.error("clearing fade on gate close failed: \(error)") }
        }
    }

    public func setFadeDuration(_ seconds: Double?) throws {
        try queue.sync {
            guard animationAllowed else { return }
            let value = seconds.map { $0.isFinite ? max($0, 0) : 0 } ?? 0
            try writeFade(value)
        }
    }

    public func setFactorTarget(_ target: FactorTarget) throws {
        try queue.sync {
            guard animationAllowed else { return }
            // Not deduplicated here: system events (display sleep/wake, dimming) can change the logical
            // state behind our back, and corebrightnessd ignores a repeat of its current target anyway.
            try writeLogicalState(target == .dark ? 1 : 2)
            factorHeld = true
        }
    }

    public func releaseFactor() throws {
        try queue.sync {
            var firstError: Error?
            if animationAllowed && factorHeld {
                do { try returnToLit() } catch { firstError = error }
            }
            factorHeld = false
            do { try writeFade(0) } catch { firstError = firstError ?? error }
            if let firstError { throw firstError }
        }
    }

    /// Fade used when animation stops, so pausing or quitting never inherits a slow effect ramp.
    private static let releaseFade: Double = 0.35

    /// Ramps the factor back to lit quickly. The fade duration is latched by corebrightnessd when the
    /// target is written, so it must be set first. (If the last target was already lit, corebrightnessd
    /// ignores the repeat and the ramp in flight finishes on its own.)
    private func returnToLit() throws {
        try writeFade(Self.releaseFade)
        try writeLogicalState(2)
    }

    private func writeFade(_ seconds: Double) throws {
        guard seconds != lastFade else { return }
        if seconds > 0 { try markModified(factor: true) }
        guard transport.setProperty(NSNumber(value: seconds), forKey: LogoKey.factorFadeDuration) else {
            lastFade = nil
            Log.driver.error("corebrightnessd rejected \(LogoKey.factorFadeDuration, privacy: .public)")
            throw LogoDriverError.writeFailed(key: LogoKey.factorFadeDuration)
        }
        lastFade = seconds
    }

    private func writeLogicalState(_ state: Int) throws {
        precondition(state == 1 || state == 2, "DisplayLogicalState may only be 1 or 2")
        try markModified(factor: true)
        guard transport.setProperty(NSNumber(value: state), forKey: LogoKey.displayLogicalState) else {
            Log.driver.error("corebrightnessd rejected \(LogoKey.displayLogicalState, privacy: .public)")
            throw LogoDriverError.writeFailed(key: LogoKey.displayLogicalState)
        }
    }

    // MARK: Restore

    public func restoreSystemDefaults(powerOn: Bool) throws {
        try queue.sync {
            var firstError: Error?
            func attempt(_ body: () throws -> Void) {
                do { try body() } catch { firstError = firstError ?? error }
            }

            let leftovers = DirtyMarker.read(from: markerURL)
            for (key, table) in LogoTables.appleDefaults.keyedTables {
                slots[key, default: TableSlot()].desired = table
                attempt { try flushTable(key, waiting: true) }
            }
            if animationAllowed && (factorHeld || leftovers?.factorModified == true) {
                attempt { try returnToLit() }
            }
            attempt { try writeFade(0) }
            factorHeld = false
            if powerOn { desiredPower = .on }
            attempt { try flushPower(waiting: true) }

            if let firstError { throw firstError }
            try DirtyMarker.remove(at: markerURL)
            marker = nil
            Log.driver.info("restored Apple's logo settings")
        }
    }

    // MARK: Dirty marker

    /// Records on disk that corebrightnessd is about to be modified. Throws if it cannot, so a
    /// modification never happens without a way to undo it.
    private func markModified(tables: Bool = false, factor: Bool = false) throws {
        if let marker, !tables || marker.tablesModified, !factor || marker.factorModified { return }
        var current = marker ?? DirtyMarker.read(from: markerURL)
            ?? DirtyMarker(pid: getpid(), since: Date(), tablesModified: false, factorModified: false)
        current.pid = getpid()
        current.tablesModified = current.tablesModified || tables
        current.factorModified = current.factorModified || factor
        do {
            try current.write(to: markerURL)
        } catch {
            Log.driver.error("cannot write dirty marker: \(error)")
            throw LogoDriverError.notAllowed("cannot write the safety marker at \(markerURL.path)")
        }
        marker = current
    }

    // MARK: Preview

    /// Cached `finalNits / 1000`, refreshed at most 10 times per second on the driver queue, so it
    /// is safe to call from the main thread or a display link.
    public func previewLevel() -> Double {
        let now = Self.now
        previewLock.lock()
        let value = previewValue
        let needsRefresh = !previewRefreshing && now - previewRefreshedAt >= Self.previewInterval
        if needsRefresh { previewRefreshing = true }
        previewLock.unlock()
        if needsRefresh {
            queue.async { [self] in
                let nits = readStateLocked()?.finalNits
                previewLock.lock()
                if let nits { previewValue = min(max(nits / LogoLimits.maxNits, 0), 1) }
                previewRefreshedAt = Self.now
                previewRefreshing = false
                previewLock.unlock()
            }
        }
        return value
    }
}
