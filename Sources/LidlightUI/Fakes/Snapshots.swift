import AppKit
import SwiftUI
import LidlightKit

/// Renders the UI to PNG files so it can be reviewed without launching the app.
package enum UISnapshots {
    @MainActor
    package static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let background = Color(nsColor: dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1))
        let content = view.background(background).environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        host.appearance = appearance
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? 1000)
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: height ?? host.fittingSize.height)
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }

    /// Writes every snapshot into `directory` and returns the file paths.
    @MainActor
    package static func renderAll(into directory: URL) throws -> [URL] {
        _ = NSApplication.shared
        var written: [URL] = []
        func save<V: View>(_ name: String, _ view: V, width: CGFloat, height: CGFloat? = nil) throws {
            for dark in [false, true] {
                let url = directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                try render(view, width: width, height: height, dark: dark, to: url)
                written.append(url)
            }
        }

        for mode in LogoMode.allCases {
            let world = FakeWorld(suiteName: "app.lidlight.snapshots", simulated: false, audio: .granted)
            world.model.start()
            world.model.setMode(mode)
            world.agents.emit(AgentSnapshot(activity: .working, sessions: 2, working: 1, needingYou: 0, updatedAt: Date()))
            world.hooks.currentStatus = .installed
            world.model.refreshHooks()
            try save("popover-\(mode.rawValue)", PopoverView(model: world.model), width: 320)
        }

        let off = FakeWorld(suiteName: "app.lidlight.snapshots", simulated: false)
        off.model.start()
        off.model.setOn(false)
        try save("popover-off", PopoverView(model: off.model), width: 320)

        let paused = FakeWorld(suiteName: "app.lidlight.snapshots", simulated: false)
        paused.model.start()
        paused.model.setMode(.breathe)
        paused.system.emit { $0.lowPowerMode = true }
        try save("popover-paused", PopoverView(model: paused.model), width: 320)

        let sim = FakeWorld(suiteName: "app.lidlight.snapshots", simulated: true, audio: .denied)
        sim.model.start()
        sim.model.setMode(.music)
        try save("popover-simulation-music-denied", PopoverView(model: sim.model), width: 320)

        let settings = FakeWorld(suiteName: "app.lidlight.snapshots")
        settings.model.start()
        settings.hooks.currentStatus = .installed
        settings.model.refreshHooks()
        try save("settings", SettingsView(model: settings.model), width: 480, height: 900)

        for (name, level) in [("preview-off", 0.0), ("preview-dim", 0.25), ("preview-bright", 1.0)] {
            try save(name, LidView(level: level).padding(24), width: 420, height: 300)
        }
        try save("preview-window", PreviewView(source: settings.driver, isSimulated: true), width: 420)
        return written
    }
}
