import SwiftUI
import AppKit

enum ClaudeTheme {
    static let accent = Color(red: 0.06, green: 0.58, blue: 0.40)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let cornerRadius: CGFloat = 12
    static let cardCornerRadius: CGFloat = 12
}

private struct ClaudeClearGlassKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var claudeClearGlass: Bool {
        get { self[ClaudeClearGlassKey.self] }
        set { self[ClaudeClearGlassKey.self] = newValue }
    }
}

// MARK: - Panels

/// Applies Apple's real Liquid Glass material on macOS 26+ (per
/// developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)),
/// and falls back to a Material-based approximation on older systems.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = ClaudeTheme.cardCornerRadius
    var tint: Color = .clear
    @Environment(\.claudeClearGlass) private var preferClearGlass

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass = preferClearGlass ? Glass.clear : Glass.clear.tint(Color.primary.opacity(0.10))
            content
                .glassEffect(
                    tint == .clear ? glass : glass.tint(tint),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint.opacity(0.06))
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = ClaudeTheme.cardCornerRadius, tint: Color = .clear) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, tint: tint))
    }

    /// Wraps content in a `GlassEffectContainer` on macOS 26+ so multiple
    /// glass panels render together and can morph, per Apple's guidance to
    /// always group Liquid Glass elements in a container. No-op fallback
    /// below macOS 26.
    @ViewBuilder
    func claudeGlassContainer(spacing: CGFloat = 16) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                self
            }
        } else {
            self
        }
    }
}

// MARK: - Buttons

/// Fallback primary button style for macOS < 26: a hand-styled glass capsule.
/// On macOS 26+, use `.claudePrimaryButton()` instead, which applies Apple's
/// real `.glassProminent` button style directly (built-in styles like
/// `.glass`/`.glassProminent` can only be applied to an actual `Button`, not
/// composed from inside another custom `ButtonStyle`).
struct ClaudeButtonStyle: ButtonStyle {
    var prominent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial, in: Capsule(style: .continuous))
            .background(
                Capsule(style: .continuous)
                    .fill(ClaudeTheme.accent.opacity(configuration.isPressed ? 0.72 : (prominent ? 0.92 : 0.55)))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75)
            )
            .foregroundColor(.white)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Fallback secondary/tertiary button style for macOS < 26 (Settings, Quit,
/// Cancel-style actions). On macOS 26+, use `.claudeGhostButton()` instead.
struct ClaudeGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(ClaudeTheme.textSecondary)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension View {
    /// Primary call-to-action button styling. Applies Apple's real
    /// `.glassProminent` glass button style on macOS 26+ (per
    /// developer.apple.com/documentation/swiftui/glassbuttonstyle), falling
    /// back to a hand-styled glass capsule on older systems.
    @ViewBuilder
    func claudePrimaryButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
                .tint(ClaudeTheme.accent)
        } else {
            self.buttonStyle(ClaudeButtonStyle())
        }
    }

    /// Secondary/tertiary button styling (Settings, Quit, Cancel). Applies
    /// Apple's real `.glass` button style on macOS 26+, falling back to a
    /// plain text-style ghost button on older systems.
    @ViewBuilder
    func claudeGhostButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(ClaudeGhostButtonStyle())
        }
    }

    func claudeGlassField() -> some View {
        modifier(ClaudeGlassFieldModifier())
    }

    func claudeGlassChoice(isSelected: Bool) -> some View {
        modifier(ClaudeGlassChoiceModifier(isSelected: isSelected))
    }
}

private struct ClaudeGlassFieldModifier: ViewModifier {
    @Environment(\.claudeClearGlass) private var preferClearGlass

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass = preferClearGlass ? Glass.clear : Glass.clear.tint(Color.primary.opacity(0.10))
            content
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .glassEffect(glass.interactive(), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            content
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct ClaudeGlassChoiceModifier: ViewModifier {
    let isSelected: Bool
    @Environment(\.claudeClearGlass) private var preferClearGlass

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let idleGlass = preferClearGlass ? Glass.clear : Glass.clear.tint(Color.primary.opacity(0.10))
            content.glassEffect(
                isSelected
                    ? .regular.tint(ClaudeTheme.accent).interactive()
                    : idleGlass.interactive(),
                in: Capsule(style: .continuous)
            )
        } else {
            content.background(
                Capsule(style: .continuous)
                    .fill(isSelected ? ClaudeTheme.accent : Color.primary.opacity(0.08))
            )
        }
    }
}

/// A fully custom Liquid Glass switch. The glass track and thumb react as a
/// single springy control instead of falling back to AppKit's flat blue
/// switch, while preserving VoiceOver through ToggleStyle.Configuration.
struct ClaudeGlassToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            // Do not put the setting mutation in a global animation transaction.
            // The clear-glass preference is an environment value used by the
            // entire window; animating that mutation makes every glass surface
            // re-materialize in one spring transaction and can stall the UI.
            configuration.isOn.toggle()
        } label: {
            ClaudeGlassToggleTrack(isOn: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

private struct ClaudeGlassToggleTrack: View {
    let isOn: Bool
    @Environment(\.claudeClearGlass) private var preferClearGlass

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            let idleGlass = preferClearGlass ? Glass.clear : Glass.clear.tint(Color.primary.opacity(0.10))
            track
                .glassEffect(
                    isOn
                        ? .regular.tint(ClaudeTheme.accent).interactive()
                        : idleGlass.interactive(),
                    in: Capsule(style: .continuous)
                )
        } else {
            track
                .background(
                    Capsule(style: .continuous)
                        .fill(isOn ? ClaudeTheme.accent : Color.primary.opacity(0.12))
                )
        }
    }

    private var track: some View {
        HStack(spacing: 0) {
            if isOn { Spacer(minLength: 0) }
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .modifier(GlassToggleThumb())
            if !isOn { Spacer(minLength: 0) }
        }
        .padding(2)
        .frame(width: 34, height: 18)
        .contentShape(Capsule(style: .continuous))
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isOn)
    }
}

private struct GlassToggleThumb: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: Circle())
        } else {
            content
        }
    }
}

// MARK: - Clean components

/// Small uppercase section label, matching the system's grouped-settings
/// look: quiet, secondary, lightly tracked.
struct SectionHeader: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundColor(ClaudeTheme.textSecondary)
    }
}

/// A smooth capsule progress bar for usage. The track stays translucent so
/// the glass shows through; small nonzero values still render a visible dot
/// (parity with the old bar's round-up rule).
struct UsageBar: View {
    let percent: Int?
    var height: CGFloat = 6
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                GlassUsageTrack()
                GlassUsageFill(color: color)
                    .frame(width: max(fraction > 0 ? height : 0, proxy.size.width * fraction))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.25), value: percent)
    }

    private var fraction: CGFloat {
        guard let percent else { return 0 }
        return CGFloat(min(max(percent, 0), 100)) / 100
    }
}

private struct GlassUsageTrack: View {
    @Environment(\.claudeClearGlass) private var preferClearGlass

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            let glass = preferClearGlass ? Glass.clear : Glass.clear.tint(Color.primary.opacity(0.10))
            Capsule(style: .continuous)
                .fill(Color.clear)
                .glassEffect(glass, in: Capsule(style: .continuous))
        } else {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
        }
    }
}

private struct GlassUsageFill: View {
    let color: Color

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            Capsule(style: .continuous)
                .fill(Color.clear)
                .glassEffect(.regular.tint(color), in: Capsule(style: .continuous))
        } else {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.8), color],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }
}

// MARK: - Window glass

/// The system's own behind-window Liquid Glass: an `NSVisualEffectView`
/// blurring whatever is behind the window, driven entirely by the system's
/// material and accessibility settings (so "Reduce transparency" is
/// respected automatically). Used as the root background of whole windows.
struct WindowGlassBackground: NSViewRepresentable {
    let clearGlass: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = clearGlass ? .underWindowBackground : .popover
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = clearGlass ? .underWindowBackground : .popover
    }
}
