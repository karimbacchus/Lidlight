import SwiftUI
import LidlightKit

/// The Settings window: General, Logo, Agents and About sections.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    private var effects: EffectSettings { model.settings.effects }

    var body: some View {
        Form {
            general
            logo
            agents
            about
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    private var general: some View {
        Section("General") {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Open at login", isOn: Binding(get: { model.settings.openAtLogin }, set: model.setOpenAtLogin))
                if let error = model.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: Binding(get: { model.settings.globalShortcutEnabled }, set: model.setGlobalShortcutEnabled)) {
                Text("Global shortcut")
                Text("⌃⌘B turns the logo on or off from anywhere.")
            }
            Toggle(isOn: Binding(get: { model.showsPreviewWindow }, set: model.setShowsPreviewWindow)) {
                Text("Show preview window")
                Text("A live picture of what the logo is doing.")
            }
        }
    }

    private var logo: some View {
        Section("Logo") {
            Toggle(isOn: Binding(get: { effects.fullBrightnessInAnyRoom }, set: model.setFullBrightnessInAnyRoom)) {
                Text("Full brightness in any room")
                Text("Lifts Apple's cap that keeps the logo dim in dark rooms.")
            }
            Toggle(isOn: Binding(get: { effects.pauseWhileKeyboardLit }, set: model.setPauseWhileKeyboardLit)) {
                Text("Pause effects while the keyboard backlight is on")
                Text("Effects switch the keyboard light off during their dark phases.")
            }
            LabeledContent {
                Button("Restore and Quit", action: model.restoreAppleLogoSettingsAndQuit)
            } label: {
                Text("Give the logo back to macOS")
                Text("Turns the logo on, restores Apple's brightness settings and quits Lidlight.")
            }
        }
    }

    private var agents: some View {
        Section("Agents") {
            AgentsConnectionRow(model: model)
            VStack(alignment: .leading, spacing: 4) {
                Text(Texts.awayLabel(seconds: effects.agentAwayAfter))
                Slider(
                    value: Binding(get: { effects.agentAwayAfter }, set: { model.setAgentAwayAfter($0.rounded()) }),
                    in: 5...120
                )
                .accessibilityLabel("Away delay")
                .accessibilityValue("\(Int(effects.agentAwayAfter)) seconds")
            }
            LabeledContent("Test the patterns") {
                HStack {
                    Button("Working") { model.previewAgents(.working) }
                    Button("Needs you") { model.previewAgents(.needsYou) }
                }
            }
        }
    }

    private var about: some View {
        Section("About") {
            HStack(spacing: 12) {
                Image(nsImage: MenuBarIcon.image(for: .animated))
                    .resizable().frame(width: 32, height: 32)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppInfo.name).font(.headline)
                    Text("Version \(AppInfo.version)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Label("No network access. Lidlight never connects to the internet.", systemImage: "wifi.slash")
            Label("Audio never leaves your Mac. It is only analyzed for beats.", systemImage: "waveform")
            Label("Claude Code hooks only report state: working, waiting or needs you.", systemImage: "terminal")
            Text("Not made by or affiliated with Apple.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
