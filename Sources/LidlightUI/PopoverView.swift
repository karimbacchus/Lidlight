import SwiftUI
import LidlightKit

/// Actions the popover asks its host to perform.
struct PopoverActions {
    var openSettings: () -> Void = {}
    var showPreview: () -> Void = {}
    var quit: () -> Void = {}
}

/// The menu bar popover: master switch, brightness, modes and per-mode controls.
struct PopoverView: View {
    @ObservedObject var model: AppModel
    var actions = PopoverActions()

    private var settings: AppSettings { model.settings }
    private var effects: EffectSettings { settings.effects }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.driver.isSimulated { simulationBanner }
            if let text = Texts.pauseBanner(model.engineStatus.pausedReason) { pausedBanner(text) }
            brightness
            Divider()
            modeList
            let controls = settings.mode.controls(audioPermission: model.audioPermission)
            if !controls.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(controls, id: \.self) { control in modeControl(control) }
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .animation(.easeInOut(duration: 0.18), value: settings.mode)
        .animation(.easeInOut(duration: 0.18), value: model.engineStatus.pausedReason)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(AppInfo.name).font(.headline)
                Text(Texts.readout(state: model.logoState, isOn: settings.isOn))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Logo brightness")
                    .accessibilityValue(settings.isOn ? Texts.readout(state: model.logoState, isOn: true) : "Off")
            }
            Spacer()
            Toggle("Logo", isOn: Binding(get: { settings.isOn }, set: { model.setOn($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Turn logo on or off")
        }
    }

    // MARK: Banners

    private func pausedBanner(_ text: String) -> some View {
        Banner(symbol: "pause.circle.fill", tint: .orange, text: text)
    }

    private var simulationBanner: some View {
        Banner(symbol: "display", tint: .blue, text: "No logo on this Mac — preview mode") {
            Button("Show preview", action: actions.showPreview)
                .controlSize(.small)
        }
    }

    // MARK: Brightness

    private var brightness: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Brightness").font(.subheadline.weight(.medium))
                Spacer()
                Text(BrightnessCurve.label(forSlider: effects.brightness))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: Binding(get: { effects.brightness }, set: { model.setBrightness($0) }), in: 0...1)
                    .accessibilityLabel("Brightness")
                    .accessibilityValue(BrightnessCurve.label(forSlider: effects.brightness))
                Image(systemName: "sun.max").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .disabled(!settings.isOn)
    }

    // MARK: Modes

    private var modeList: some View {
        VStack(spacing: 2) {
            ForEach(LogoMode.allCases) { mode in
                ModeRow(mode: mode, isSelected: mode == settings.mode) { model.setMode(mode) }
            }
        }
    }

    @ViewBuilder
    private func modeControl(_ control: ModeControl) -> some View {
        switch control {
        case .breatheSpeed:
            LabeledSlider(
                title: "Speed",
                value: Binding(
                    get: { BreatheSpeed.slider(forPeriod: effects.breathePeriod) },
                    set: { model.setBreathePeriod(BreatheSpeed.period(forSlider: $0)) }
                ),
                valueLabel: BreatheSpeed.label(forPeriod: effects.breathePeriod),
                leading: "Slow", trailing: "Fast"
            )
        case .musicIntensity:
            LabeledSlider(
                title: "Intensity",
                value: Binding(get: { effects.musicIntensity }, set: { model.setMusicIntensity($0) }),
                valueLabel: Percent.label(effects.musicIntensity),
                leading: "Subtle", trailing: "Strong"
            )
        case .musicStrobe:
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Strobe", isOn: Binding(get: { effects.musicStrobe }, set: { model.setMusicStrobe($0) }))
                    .toggleStyle(.switch)
                Text("Extra flashes on strong beats; flashes are capped at 3 per second.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .musicPermission:
            permissionRow
        case .agentsConnection:
            AgentsConnectionRow(model: model, compact: true)
        case .agentsLive:
            Label(Texts.agentsLine(model.agentSnapshot), systemImage: "terminal")
                .font(.callout).foregroundStyle(.secondary)
        case .batteryCharge:
            Label(Texts.batteryLine(model.systemStatus), systemImage: "battery.75percent")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(Texts.permissionText(model.audioPermission) ?? "", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if model.audioPermission != .unsupported {
                Button("Open System Settings…", action: model.openAudioPrivacySettings)
                    .controlSize(.small)
                Text("Privacy & Security › Screen & System Audio Recording")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Settings…", action: actions.openSettings)
                .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button("Quit", action: actions.quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }
}

// MARK: - Components

/// Hover tracking without `@State`: the SwiftUI macro plugin isn't available with Command Line Tools only.
private final class HoverState: ObservableObject {
    @Published var isHovering = false
}

private struct ModeRow: View {
    let mode: LogoMode
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.title).font(.body.weight(.medium))
                    Text(mode.subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hover.isHovering ? 0.07 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
        .accessibilityLabel("\(mode.title). \(mode.subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let valueLabel: String
    let leading: String
    let trailing: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(valueLabel).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...1)
                .accessibilityLabel(title)
                .accessibilityValue(valueLabel)
            HStack {
                Text(leading); Spacer(); Text(trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }
}

struct Banner<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

extension Banner where Trailing == EmptyView {
    init(symbol: String, tint: Color, text: String) {
        self.init(symbol: symbol, tint: tint, text: text) { EmptyView() }
    }
}

/// "Claude Code: Connected" with a Connect/Disconnect button.
struct AgentsConnectionRow: View {
    @ObservedObject var model: AppModel
    var compact = false

    private var isConnected: Bool {
        switch model.hooksStatus {
        case .installed, .needsUpdate: return true
        case .notInstalled, .error: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude Code").font(.subheadline.weight(.medium))
                    Text(Texts.hooksSummary(model.hooksStatus))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.hooksStatus == .needsUpdate {
                    Button("Update", action: model.connectAgents).controlSize(.small)
                }
                Button(isConnected ? "Disconnect" : "Connect") {
                    isConnected ? model.disconnectAgents() : model.connectAgents()
                }
                .controlSize(compact ? .small : .regular)
            }
            if let error = model.hooksError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
