import AppKit
import Foundation
import IOKit
import IOKit.ps
import LidlightKit

/// Observes display, lock, power, lid, battery, idle and keyboard-backlight state.
///
/// All work happens on the main thread; call `start`/`stop` from the main thread. `onChange` fires
/// (on main) only when the resulting `SystemStatus` differs from the previous one. Event-driven fields
/// update immediately on their notifications; `userIdleSeconds` (rounded to whole seconds) and
/// `keyboardBacklightLit` are sampled on a 2 s poll, which also backs up the display and lid readings.
/// Read-only: nothing here changes any system setting.
public final class SystemMonitor: SystemMonitoring {
    private static let pollInterval: TimeInterval = 2

    private let keyboardProbe: KeyboardBacklightProbing?
    public private(set) var status = SystemStatus()

    private var onChange: ((SystemStatus) -> Void)?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var pollTimer: Timer?
    private var batterySource: CFRunLoopSource?
    private var lidPort: IONotificationPortRef?
    private var lidNotifier: io_object_t = 0
    private var lidService: io_service_t = 0
    private var lockedByNotification = false
    private var sessionInactive = false

    public init(keyboardProbe: KeyboardBacklightProbing?) {
        self.keyboardProbe = keyboardProbe
    }

    /// Starts observing and reports the current status immediately. Does nothing if already started.
    public func start(onChange: @escaping (SystemStatus) -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange
        lockedByNotification = SystemReaders.screenLocked()
        refreshAll()
        onChange(status)
        installObservers()
        installBatterySource()
        installLidNotification()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Removes every observer, run-loop source and timer. Safe to call repeatedly.
    public func stop() {
        guard onChange != nil else { return }
        onChange = nil
        pollTimer?.invalidate()
        pollTimer = nil
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
        if let source = batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            batterySource = nil
        }
        removeLidNotification()
    }

    // MARK: Refresh

    /// Re-reads the event-driven fields, and also the polled samples (idle, keyboard) when `includePolled`.
    private func refresh(includePolled: Bool) {
        var next = status
        next.displayAsleep = MacHardware.builtInDisplayAsleep()
        next.screenLocked = lockedByNotification || sessionInactive
        next.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        next.lidClosed = MacHardware.lidClosed()
        let battery = SystemReaders.battery()
        next.onBattery = battery.onBattery
        next.batteryPercent = battery.percent
        next.isCharging = battery.isCharging
        if includePolled {
            next.userIdleSeconds = SystemReaders.userIdleSeconds().rounded(.down)
            next.keyboardBacklightLit = keyboardProbe?.isBuiltInKeyboardLit() ?? false
        }
        publish(next)
    }

    private func refreshAll() { refresh(includePolled: true) }
    private func refreshEventDriven() { refresh(includePolled: false) }

    private func publish(_ next: SystemStatus) {
        guard next != status, let onChange else { return }
        status = next
        onChange(next)
    }

    // MARK: Observers

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let local = NotificationCenter.default

        func observe(_ center: NotificationCenter, _ name: Notification.Name,
                     _ handler: @escaping (SystemMonitor) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if let self { handler(self) }
            }
            observers.append((center, token))
        }

        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            observe(workspace, name) { $0.refreshEventDriven() }
        }
        observe(local, NSApplication.didChangeScreenParametersNotification) { $0.refreshEventDriven() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) {
            $0.sessionInactive = true
            $0.refreshEventDriven()
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) {
            $0.sessionInactive = false
            $0.lockedByNotification = SystemReaders.screenLocked()
            $0.refreshEventDriven()
        }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) {
            $0.lockedByNotification = true
            $0.refreshEventDriven()
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) {
            $0.lockedByNotification = false
            $0.refreshEventDriven()
        }
        observe(local, .NSProcessInfoPowerStateDidChange) { $0.refreshEventDriven() }
    }

    private func installBatterySource() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            Unmanaged<SystemMonitor>.fromOpaque(context).takeUnretainedValue().refreshEventDriven()
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            Log.system.error("IOPSNotificationCreateRunLoopSource failed; battery updates fall back to the poll")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        batterySource = source
    }

    private func installLidNotification() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.system.error("Lid notification unavailable; lid state falls back to the poll")
            if service != 0 { IOObjectRelease(service) }
            return
        }
        IONotificationPortSetDispatchQueue(port, .main)
        let callback: IOServiceInterestCallback = { context, _, _, _ in
            guard let context else { return }
            Unmanaged<SystemMonitor>.fromOpaque(context).takeUnretainedValue().refreshEventDriven()
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var notifier: io_object_t = 0
        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, callback, context, &notifier)
        guard result == KERN_SUCCESS else {
            Log.system.error("IOServiceAddInterestNotification failed (\(result)); lid state falls back to the poll")
            IONotificationPortDestroy(port)
            IOObjectRelease(service)
            return
        }
        lidPort = port
        lidService = service
        lidNotifier = notifier
    }

    private func removeLidNotification() {
        if lidNotifier != 0 { IOObjectRelease(lidNotifier); lidNotifier = 0 }
        if let port = lidPort { IONotificationPortDestroy(port); lidPort = nil }
        if lidService != 0 { IOObjectRelease(lidService); lidService = 0 }
    }
}
