import Foundation
import LidlightKit

/// Starts `lidlightctl guard` tied to the app by a pipe, so Apple's settings are restored even
/// if the app crashes or is force-quit.
public enum GuardianLauncher {
    private static let lock = NSLock()
    private static var running: (process: Process, stdin: FileHandle)?

    /// Launches `helperURL guard --parent-pid <this pid>` once per process. The write end of the
    /// guardian's stdin stays open for the lifetime of this process; its closing (exit or crash)
    /// is the guardian's cue. Returns nil if the helper cannot be started.
    @discardableResult
    public static func launch(helperURL: URL) -> Process? {
        lock.lock()
        defer { lock.unlock() }
        if let running, running.process.isRunning { return running.process }
        guard let spawned = spawn(helperURL: helperURL, arguments: ["guard", "--parent-pid", String(getpid())]) else {
            return nil
        }
        running = spawned
        return spawned.process
    }

    /// Starts `helperURL` with a pipe on its stdin and null stdout/stderr. The caller owns the
    /// returned write end.
    package static func spawn(helperURL: URL, arguments: [String]) -> (process: Process, stdin: FileHandle)? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments
        process.standardInput = pipe.fileHandleForReading
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.driver.error("cannot start guardian \(helperURL.path, privacy: .public): \(error)")
            return nil
        }
        try? pipe.fileHandleForReading.close()
        return (process, pipe.fileHandleForWriting)
    }
}

/// The guardian process behind `lidlightctl guard --parent-pid <pid>`.
enum Guardian {
    /// Blocks until stdin reaches EOF or `parentPID` exits, then restores Apple's settings if a
    /// dirty marker exists. Ignores SIGINT/SIGTERM/SIGHUP so only the parent's death ends it.
    /// Never changes `LEBacklightMode`: the user's on/off choice stands.
    static func run(parentPID: Int32, driver: LogoDriving, markerURL: URL = AppPaths.dirtyMarkerURL) -> Int32 {
        for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { signal(signalNumber, SIG_IGN) }

        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var byte = UInt8(0)
            while true {
                let count = read(STDIN_FILENO, &byte, 1)
                if count == 0 || (count < 0 && errno != EINTR) { break }
            }
            finished.signal()
        }
        Thread.detachNewThread {
            waitForExit(of: parentPID)
            finished.signal()
        }
        finished.wait()

        Log.driver.info("guardian: parent \(parentPID) is gone")
        SafetyRecovery.recover(driver: driver, markerURL: markerURL, requireOwnerExit: false)
        return 0
    }

    /// Returns when `pid` has exited (or never existed).
    private static func waitForExit(of pid: Int32) {
        let queueDescriptor = kqueue()
        guard queueDescriptor >= 0 else { return }
        defer { close(queueDescriptor) }
        var change = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        var event = kevent()
        while true {
            let count = kevent(queueDescriptor, &change, 1, &event, 1, nil)
            if count > 0 || (count < 0 && errno != EINTR) { return }
            change = kevent()
        }
    }
}

/// On launch: if a previous run left corebrightnessd modified (dirty marker present), restore it.
public enum SafetyRecovery {
    /// Restores Apple's tables and clears overrides when a marker from a process that is no longer
    /// running exists. Leaves `LEBacklightMode` alone.
    public static func recoverIfNeeded(driver: LogoDriving) {
        recover(driver: driver, markerURL: AppPaths.dirtyMarkerURL, requireOwnerExit: true)
    }

    /// With `requireOwnerExit`, a marker whose writing process still runs is left alone (it is
    /// another live instance, or the caller itself).
    @discardableResult
    package static func recover(driver: LogoDriving, markerURL: URL, requireOwnerExit: Bool) -> Bool {
        guard let marker = DirtyMarker.read(from: markerURL) else { return false }
        if requireOwnerExit && marker.pid != getpid() && marker.ownerIsAlive {
            Log.driver.info("dirty marker belongs to running process \(marker.pid); not recovering")
            return false
        }
        Log.driver.notice("recovering from an unclean exit (tables: \(marker.tablesModified), factor: \(marker.factorModified))")
        driver.setAnimationAllowed(AnimationEnvironment.isPossible())
        do {
            try driver.restoreSystemDefaults(powerOn: false)
            return true
        } catch {
            Log.driver.error("recovery failed: \(error)")
            return false
        }
    }
}
