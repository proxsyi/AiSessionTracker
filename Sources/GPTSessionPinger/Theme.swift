import SwiftUI
import TrackerDesignSystem

/// GPT/Codex own only their green brand token. The shared design target owns
/// every glass primitive, so this module can add provider UI without copying
/// its visual implementation.
enum GPTTheme {
    static let accent = Color(red: 0.06, green: 0.58, blue: 0.40)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let cornerRadius = TrackerDesign.cornerRadius
    static let cardCornerRadius = TrackerDesign.cardCornerRadius
}

private struct GPTClearGlassKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var gptClearGlass: Bool {
        get { self[GPTClearGlassKey.self] }
        set { self[GPTClearGlassKey.self] = newValue }
    }
}

struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = GPTTheme.cardCornerRadius
    var tint: Color = .clear
    @Environment(\.gptClearGlass) private var clearGlass

    func body(content: Content) -> some View {
        content.trackerGlassPanel(cornerRadius: cornerRadius, tint: tint, clearGlass: clearGlass)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = GPTTheme.cardCornerRadius, tint: Color = .clear) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, tint: tint))
    }

    func gptGlassContainer(spacing: CGFloat = 16) -> some View {
        trackerGlassContainer(spacing: spacing)
    }

    func gptPrimaryButton() -> some View { trackerPrimaryButton(accent: GPTTheme.accent) }
    func gptGhostButton() -> some View { trackerGhostButton() }
    func gptGlassField() -> some View { modifier(GPTGlassFieldModifier()) }
    func gptGlassChoice(isSelected: Bool) -> some View { modifier(GPTGlassChoiceModifier(isSelected: isSelected)) }
}

private struct GPTGlassFieldModifier: ViewModifier {
    @Environment(\.gptClearGlass) private var clearGlass
    func body(content: Content) -> some View { content.modifier(TrackerGlassField(clearGlass: clearGlass)) }
}

private struct GPTGlassChoiceModifier: ViewModifier {
    let isSelected: Bool
    @Environment(\.gptClearGlass) private var clearGlass
    func body(content: Content) -> some View {
        content.modifier(TrackerGlassChoice(isSelected: isSelected, accent: GPTTheme.accent, clearGlass: clearGlass))
    }
}

struct GPTGlassToggleStyle: ToggleStyle {
    @Environment(\.gptClearGlass) private var clearGlass
    func makeBody(configuration: Configuration) -> some View {
        TrackerGlassToggleStyle(accent: GPTTheme.accent, clearGlass: clearGlass).makeBody(configuration: configuration)
    }
}

typealias SectionHeader = TrackerSectionHeader
typealias WindowGlassBackground = TrackerWindowGlassBackground

struct UsageBar: View {
    let percent: Int?
    var height: CGFloat = 6
    var color: Color
    @Environment(\.gptClearGlass) private var clearGlass

    var body: some View {
        TrackerUsageBar(percent: percent, height: height, color: color, clearGlass: clearGlass)
    }
}
