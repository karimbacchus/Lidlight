import AppKit
import Combine
import SwiftUI
import LidlightKit

/// Owns the status item, popover, settings window, hotkey and app lifecycle.
public final class AppController: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()

    public init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Call once, before `NSApplication.run()`.
    public func start() {
        NSApplication.shared.delegate = self
        model.start()
        configureStatusItem()
        configurePopover()
        hotKey = GlobalHotKey { [weak self] in self?.model.toggleOn() }
        bind()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    // MARK: Status item

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        updateIcon()
    }

    private func updateIcon() {
        let state = MenuBarIconState(status: model.engineStatus)
        statusItem?.button?.image = MenuBarIcon.image(for: state)
        statusItem?.button?.toolTip = state.accessibilityDescription
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSEvent.modifierFlags.contains(.option) {
            model.toggleOn()
        } else {
            togglePopover()
        }
    }

    // MARK: Popover

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let actions = PopoverActions(
            openSettings: { [weak self] in self?.showSettings() },
            showPreview: { [weak self] in self?.model.setShowsPreviewWindow(true) },
            quit: { NSApplication.shared.terminate(nil) }
        )
        let host = NSHostingController(rootView: PopoverView(model: model, actions: actions))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem?.button {
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    public func popoverDidShow(_ notification: Notification) { model.setPopoverVisible(true) }
    public func popoverDidClose(_ notification: Notification) { model.setPopoverVisible(false) }

    // MARK: Bindings

    private func bind() {
        model.$engineStatus
            .map(MenuBarIconState.init(status:))
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        model.$settings
            .map(\.globalShortcutEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                enabled ? self?.hotKey?.register() : self?.hotKey?.unregister()
            }
            .store(in: &cancellables)
        model.$showsPreviewWindow
            .removeDuplicates()
            .sink { [weak self] show in show ? self?.openPreviewWindow() : self?.closePreviewWindow() }
            .store(in: &cancellables)
    }

    @objc private func appDidBecomeActive() {
        model.refreshAudioAccess()
        model.refreshLoginItem()
        model.refreshHooks()
    }

    // MARK: Windows

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "\(AppInfo.name) Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        model.refreshLoginItem()
        model.refreshHooks()
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func openPreviewWindow() {
        if previewWindow == nil {
            let host = NSHostingController(rootView: PreviewView(source: model.preview, isSimulated: model.driver.isSimulated))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Logo Preview"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            previewWindow = window
        }
        previewWindow?.makeKeyAndOrderFront(nil)
    }

    private func closePreviewWindow() {
        previewWindow?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === previewWindow { model.setShowsPreviewWindow(false) }
    }

    // MARK: Quit

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let decision: QuitFlow.Decision = model.quitRestoringAppleSettings
            ? .quit(keepOff: false)
            : QuitFlow.decision(logoIsOn: model.settings.isOn)
        switch decision {
        case .quit(let keepOff):
            model.finishQuit(keepOff: keepOff)
        case .askKeepOff:
            model.finishQuit(keepOff: askToKeepLogoOff())
        }
        return .terminateNow
    }

    /// True if the user wants the logo to stay off after Lidlight quits.
    private func askToKeepLogoOff() -> Bool {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "Keep the logo off after Lidlight quits?"
        alert.informativeText = "Quitting puts Apple's logo settings back. Choose whether the logo should stay off or light up again."
        alert.addButton(withTitle: "Keep Off")
        alert.addButton(withTitle: "Turn On")
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
