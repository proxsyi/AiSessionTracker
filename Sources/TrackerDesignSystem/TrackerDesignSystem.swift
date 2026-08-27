import AppKit
import SwiftUI

/// Shared visual primitives for every provider tab. Provider modules own their
/// accent color and business/UI-specific content, but never duplicate the
/// glass, button, field, toggle, progress, or window-material implementation.
public enum TrackerDesign {
    public static let cornerRadius: CGFloat = 12
    public static let cardCornerRadius: CGFloat = 12
}

public struct TrackerGlassPanel: ViewModifier {
    public var cornerRadius: CGFloat
    public var tint: Color
    public var clearGlass: Bool

    public init(cornerRadius: CGFloat = TrackerDesign.cardCornerRadius, tint: Color = .clear, clearGlass: Bool = true) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.clearGlass = clearGlass
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass = clearGlass ? Glass.clear : Glass.clear.tint(Color.primary.opacity(0.10))
            content.glassEffect(
                tint == .clear ? glass : glass.tint(tint),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(tint.opacity(0.06))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

public struct TrackerPrimaryButtonStyle: ButtonStyle {
    public var accent: Color

    public init(accent: Color) { self.accent = accent }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial, in: Capsule(style: .continuous))
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(configuration.isPressed ? 0.72 : 0.92))
            )
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75))
            .foregroundColor(.white)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

public struct TrackerGhostButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

public struct TrackerGlassField: ViewModifier {
    public var clearGlass: Bool
    public init(clearGlass: Bool) { self.clearGlass = clearGlass }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass = clearGlass ? Glass.clear : Glass.clear.tint(Color.primary.opacity(0.10))
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

public struct TrackerGlassChoice: ViewModifier {
    public var isSelected: Bool
    public var accent: Color
    public var clearGlass: Bool

    public init(isSelected: Bool, accent: Color, clearGlass: Bool) {
        self.isSelected = isSelected
        self.accent = accent
        self.clearGlass = clearGlass
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let idleGlass = clearGlass ? Glass.clear : Glass.clear.tint(Color.primary.opacity(0.10))
            content.glassEffect(
                isSelected ? .regular.tint(accent).interactive() : idleGlass.interactive(),
                in: Capsule(style: .continuous)
            )
        } else {
            content.background(Capsule(style: .continuous).fill(isSelected ? accent : Color.primary.opacity(0.08)))
        }
    }
}

public struct TrackerGlassToggleStyle: ToggleStyle {
    public var accent: Color
    public var clearGlass: Bool

    public init(accent: Color, clearGlass: Bool) {
        self.accent = accent
        self.clearGlass = clearGlass
    }

    public func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            TrackerGlassToggleTrack(isOn: configuration.isOn, accent: accent, clearGlass: clearGlass)
        }
        .buttonStyle(.plain)
    }
}

private struct TrackerGlassToggleTrack: View {
    let isOn: Bool
    let accent: Color
    let clearGlass: Bool

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            let idleGlass = clearGlass ? Glass.clear : Glass.clear.tint(Color.primary.opacity(0.10))
            track.glassEffect(
                isOn ? .regular.tint(accent).interactive() : idleGlass.interactive(),
                in: Capsule(style: .continuous)
            )
        } else {
            track.background(Capsule(style: .continuous).fill(isOn ? accent : Color.primary.opacity(0.12)))
        }
    }

    private var track: some View {
        HStack(spacing: 0) {
            if isOn { Spacer(minLength: 0) }
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .modifier(TrackerGlassToggleThumb())
            if !isOn { Spacer(minLength: 0) }
        }
        .padding(2)
        .frame(width: 34, height: 18)
        .contentShape(Capsule(style: .continuous))
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isOn)
    }
}

private struct TrackerGlassToggleThumb: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: Circle())
        } else {
            content
        }
    }
}

public struct TrackerSectionHeader: View {
    public let text: String
    public init(text: String) { self.text = text }

    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundColor(.secondary)
    }
}

public struct TrackerUsageBar: View {
    public let percent: Int?
    public var height: CGFloat
    public var color: Color
    public var clearGlass: Bool

    public init(percent: Int?, height: CGFloat = 6, color: Color, clearGlass: Bool) {
        self.percent = percent
        self.height = height
        self.color = color
        self.clearGlass = clearGlass
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                track
                fill.frame(width: max(fraction > 0 ? height : 0, proxy.size.width * fraction))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.25), value: percent)
    }

    private var fraction: CGFloat {
        guard let percent else { return 0 }
        return CGFloat(min(max(percent, 0), 100)) / 100
    }

    @ViewBuilder
    private var track: some View {
        if #available(macOS 26.0, *) {
            let glass = clearGlass ? Glass.clear : Glass.clear.tint(Color.primary.opacity(0.10))
            Capsule(style: .continuous).fill(Color.clear).glassEffect(glass, in: Capsule(style: .continuous))
        } else {
            Capsule(style: .continuous).fill(Color.primary.opacity(0.08))
        }
    }

    @ViewBuilder
    private var fill: some View {
        if #available(macOS 26.0, *) {
            Capsule(style: .continuous).fill(Color.clear).glassEffect(.regular.tint(color), in: Capsule(style: .continuous))
        } else {
            Capsule(style: .continuous).fill(LinearGradient(colors: [color.opacity(0.8), color], startPoint: .leading, endPoint: .trailing))
        }
    }
}

public struct TrackerWindowGlassBackground: NSViewRepresentable {
    public let clearGlass: Bool
    public init(clearGlass: Bool) { self.clearGlass = clearGlass }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = clearGlass ? .underWindowBackground : .popover
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = clearGlass ? .underWindowBackground : .popover
    }
}

public extension View {
    func trackerGlassPanel(cornerRadius: CGFloat = TrackerDesign.cardCornerRadius, tint: Color = .clear, clearGlass: Bool = true) -> some View {
        modifier(TrackerGlassPanel(cornerRadius: cornerRadius, tint: tint, clearGlass: clearGlass))
    }

    @ViewBuilder
    func trackerGlassContainer(spacing: CGFloat = 16) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    @ViewBuilder
    func trackerPrimaryButton(accent: Color) -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(accent)
        } else {
            self.buttonStyle(TrackerPrimaryButtonStyle(accent: accent))
        }
    }

    @ViewBuilder
    func trackerGhostButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(TrackerGhostButtonStyle())
        }
    }
}
