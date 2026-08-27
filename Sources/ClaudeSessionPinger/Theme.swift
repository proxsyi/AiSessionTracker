import SwiftUI
import TrackerDesignSystem

/// Claude owns only its brand tokens. The entire visual implementation lives
/// in TrackerDesignSystem so Claude, Codex, and ChatGPT cannot drift apart.
enum ClaudeTheme {
    static let accent = Color(red: 0.80, green: 0.40, blue: 0.27)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let cornerRadius = TrackerDesign.cornerRadius
    static let cardCornerRadius = TrackerDesign.cardCornerRadius
}

private struct ClaudeClearGlassKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var claudeClearGlass: Bool {
        get { self[ClaudeClearGlassKey.self] }
        set { self[ClaudeClearGlassKey.self] = newValue }
    }
}

struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = ClaudeTheme.cardCornerRadius
    var tint: Color = .clear
    @Environment(\.claudeClearGlass) private var clearGlass

    func body(content: Content) -> some View {
        content.trackerGlassPanel(cornerRadius: cornerRadius, tint: tint, clearGlass: clearGlass)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = ClaudeTheme.cardCornerRadius, tint: Color = .clear) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, tint: tint))
    }

    func claudeGlassContainer(spacing: CGFloat = 16) -> some View {
        trackerGlassContainer(spacing: spacing)
    }

    func claudePrimaryButton() -> some View { trackerPrimaryButton(accent: ClaudeTheme.accent) }
    func claudeGhostButton() -> some View { trackerGhostButton() }
    func claudeGlassField() -> some View { modifier(ClaudeGlassFieldModifier()) }
    func claudeGlassChoice(isSelected: Bool) -> some View { modifier(ClaudeGlassChoiceModifier(isSelected: isSelected)) }
}

private struct ClaudeGlassFieldModifier: ViewModifier {
    @Environment(\.claudeClearGlass) private var clearGlass
    func body(content: Content) -> some View { content.modifier(TrackerGlassField(clearGlass: clearGlass)) }
}

private struct ClaudeGlassChoiceModifier: ViewModifier {
    let isSelected: Bool
    @Environment(\.claudeClearGlass) private var clearGlass
    func body(content: Content) -> some View {
        content.modifier(TrackerGlassChoice(isSelected: isSelected, accent: ClaudeTheme.accent, clearGlass: clearGlass))
    }
}

struct ClaudeGlassToggleStyle: ToggleStyle {
    @Environment(\.claudeClearGlass) private var clearGlass
    func makeBody(configuration: Configuration) -> some View {
        TrackerGlassToggleStyle(accent: ClaudeTheme.accent, clearGlass: clearGlass).makeBody(configuration: configuration)
    }
}

typealias SectionHeader = TrackerSectionHeader
typealias WindowGlassBackground = TrackerWindowGlassBackground

struct UsageBar: View {
    let percent: Int?
    var height: CGFloat = 6
    var color: Color
    @Environment(\.claudeClearGlass) private var clearGlass

    var body: some View {
        TrackerUsageBar(percent: percent, height: height, color: color, clearGlass: clearGlass)
    }
}
