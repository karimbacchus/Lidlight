import SwiftUI
import LidlightKit

/// A stylized laptop lid with an abstract glowing mark, driven by `LogoPreviewSource`.
struct PreviewView: View {
    let source: LogoPreviewSource
    let isSimulated: Bool

    var body: some View {
        VStack(spacing: 14) {
            TimelineView(.animation) { _ in
                LidView(level: source.previewLevel())
            }
            .frame(height: 230)
            Text(isSimulated ? "Simulated preview" : "Live preview of the lid logo")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The lid and its mark at one brightness level (0...1).
struct LidView: View {
    let level: Double

    var body: some View {
        // Perceived brightness is much flatter than nits.
        let glow = pow(min(max(level, 0), 1), 0.55)
        let warm = Color(red: 1, green: 0.96, blue: 0.88)
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.19)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [warm.opacity(0.55 * glow), warm.opacity(0.18 * glow), .clear],
                                         center: .center, startRadius: 8, endRadius: 100))
                    .frame(width: 200, height: 200)
                Circle()
                    .strokeBorder(warm, lineWidth: 5)
                    .frame(width: 66, height: 66)
                    .opacity(0.12 + 0.88 * glow)
                Circle()
                    .fill(warm)
                    .frame(width: 24, height: 24)
                    .opacity(0.12 + 0.88 * glow)
            }
            VStack {
                Spacer()
                Capsule().fill(.black.opacity(0.25)).frame(width: 90, height: 5).padding(.bottom, 10)
            }
        }
        .frame(width: 360)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
        .accessibilityElement()
        .accessibilityLabel("Logo preview")
        .accessibilityValue(Percent.label(level))
    }
}
