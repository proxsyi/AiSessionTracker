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

/// The common dashboard stack used by every service inside the menu-bar
/// popover. Provider modules supply data and actions; spacing, card material,
/// typography, and row alignment stay identical.
public struct TrackerMenuStack<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .trackerGlassContainer(spacing: 12)
    }
}

public struct TrackerMenuCard<Content: View>: View {
    private let clearGlass: Bool
    private let content: Content

    public init(clearGlass: Bool, @ViewBuilder content: () -> Content) {
        self.clearGlass = clearGlass
        self.content = content()
    }

    public var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .trackerGlassPanel(clearGlass: clearGlass)
    }
}

public struct TrackerMenuUsageRow: View {
    private let title: String
    private let value: String
    private let percent: Int?
    private let detail: String?
    private let missingDetail: String?
    private let valueColor: Color
    private let clearGlass: Bool
    private let showsBar: Bool

    public init(
        title: String,
        value: String,
        percent: Int?,
        detail: String?,
        missingDetail: String? = nil,
        valueColor: Color,
        clearGlass: Bool,
        showsBar: Bool = true
    ) {
        self.title = title
        self.value = value
        self.percent = percent
        self.detail = detail
        self.missingDetail = missingDetail
        self.valueColor = valueColor
        self.clearGlass = clearGlass
        self.showsBar = showsBar
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(valueColor)
            }
            if showsBar {
                TrackerUsageBar(percent: percent, color: valueColor, clearGlass: clearGlass)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else if percent == nil, let missingDetail {
                Text(missingDetail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}

public struct TrackerMenuServiceStatus: View {
    private let message: String
    private let detail: String
    private let statusColor: Color
    private let help: String
    private let onOpen: () -> Void

    public init(
        message: String,
        detail: String,
        statusColor: Color,
        help: String,
        onOpen: @escaping () -> Void
    ) {
        self.message = message
        self.detail = detail
        self.statusColor = statusColor
        self.help = help
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help(help)
    }
}

/// Claude and Codex use the same pinger/countdown card. The provider supplies
/// only its dates, status text, accent-styled button, and feature names.
public struct TrackerMenuSessionCard<Action: View>: View {
    private let title: String
    private let countdown: String
    private let secondary: String?
    private let status: String?
    private let statusColor: Color
    private let action: Action

    public init(
        title: String,
        countdown: String,
        secondary: String?,
        status: String? = nil,
        statusColor: Color = .secondary,
        @ViewBuilder action: () -> Action
    ) {
        self.title = title
        self.countdown = countdown
        self.secondary = secondary
        self.status = status
        self.statusColor = statusColor
        self.action = action()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                TrackerSectionHeader(text: title)
                Text(countdown)
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let status {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundColor(statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            action
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The common settings information architecture. Provider modules supply only
/// the cards inside each page; the rail, spacing, scrolling, and footer shell
/// are rendered once here for Claude, Codex, and ChatGPT.
public enum TrackerSettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case usage = "Usage"
    case alerts = "Alerts"
    case app = "App"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .usage: return "chart.bar.fill"
        case .alerts: return "bell.fill"
        case .app: return "gearshape.fill"
        }
    }
}

public struct TrackerSettingsTabRail: View {
    @Binding private var selection: TrackerSettingsTab
    private let accent: Color
    private let secondary: Color
    private let clearGlass: Bool

    public init(
        selection: Binding<TrackerSettingsTab>,
        accent: Color,
        secondary: Color = .secondary,
        clearGlass: Bool
    ) {
        _selection = selection
        self.accent = accent
        self.secondary = secondary
        self.clearGlass = clearGlass
    }

    public var body: some View {
        GeometryReader { proxy in
            if #available(macOS 26.0, *) {
                let railGlass = clearGlass ? Glass.clear : Glass.clear.tint(Color.primary.opacity(0.10))
                let tabCount = CGFloat(TrackerSettingsTab.allCases.count)
                let indicatorWidth = max((proxy.size.width - 8) / tabCount, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(accent.opacity(0.88))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                        )
                        .frame(width: indicatorWidth, height: 30)
                        .offset(x: indicatorWidth * CGFloat(selectedIndex))
                        .animation(.easeInOut(duration: 0.20), value: selection)

                    HStack(spacing: 0) {
                        ForEach(TrackerSettingsTab.allCases) { tab in
                            Button { select(tab) } label: {
                                Label(tab.rawValue, systemImage: tab.symbol)
                                    .font(.system(size: 11, weight: selection == tab ? .semibold : .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .contentShape(Capsule(style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(selection == tab ? Color.white : secondary)
                        }
                    }
                    .animation(.easeInOut(duration: 0.14), value: selection)
                }
                .padding(4)
                .frame(maxWidth: .infinity)
                .contentShape(Capsule(style: .continuous))
                .glassEffect(railGlass, in: Capsule(style: .continuous))
                .simultaneousGesture(tabDragGesture(width: proxy.size.width))
            } else {
                Picker("Settings section", selection: $selection) {
                    ForEach(TrackerSettingsTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .frame(height: 42)
    }

    private var selectedIndex: Int {
        TrackerSettingsTab.allCases.firstIndex(of: selection) ?? 0
    }

    private func select(_ tab: TrackerSettingsTab) {
        guard tab != selection else { return }
        selection = tab
    }

    private func tabDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3).onChanged { value in
            let available = max(width - 8, 1)
            let x = min(max(value.location.x - 4, 0), available - 1)
            let index = min(
                Int(x / (available / CGFloat(TrackerSettingsTab.allCases.count))),
                TrackerSettingsTab.allCases.count - 1
            )
            select(TrackerSettingsTab.allCases[index])
        }
    }
}

public struct TrackerSettingsWindow<Content: View, Footer: View>: View {
    @Binding private var selectedTab: TrackerSettingsTab
    private let accent: Color
    private let secondary: Color
    private let clearGlass: Bool
    private let topLeadingInset: CGFloat
    private let frameWidth: CGFloat
    private let frameHeight: CGFloat
    private let content: Content
    private let footer: Footer

    public init(
        selectedTab: Binding<TrackerSettingsTab>,
        accent: Color,
        secondary: Color = .secondary,
        clearGlass: Bool,
        topLeadingInset: CGFloat,
        frameWidth: CGFloat,
        frameHeight: CGFloat,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        _selectedTab = selectedTab
        self.accent = accent
        self.secondary = secondary
        self.clearGlass = clearGlass
        self.topLeadingInset = topLeadingInset
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(spacing: 0) {
            TrackerSettingsTabRail(
                selection: $selectedTab,
                accent: accent,
                secondary: secondary,
                clearGlass: clearGlass
            )
            .padding(.leading, 8 + topLeadingInset)
            .padding(.trailing, 8)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                content.padding(20)
            }
            .scrollIndicators(.hidden)
            .clipped()

            Divider()
            footer.background(TrackerWindowGlassBackground(clearGlass: clearGlass))
        }
        .frame(width: frameWidth, height: frameHeight)
        .background(TrackerWindowGlassBackground(clearGlass: clearGlass).ignoresSafeArea())
    }
}

public struct TrackerSettingsCard<Content: View>: View {
    private let clearGlass: Bool
    private let content: Content

    public init(clearGlass: Bool, @ViewBuilder content: () -> Content) {
        self.clearGlass = clearGlass
        self.content = content()
    }

    public var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .trackerGlassPanel(clearGlass: clearGlass)
    }
}

public struct TrackerSettingsToggleRow: View {
    private let title: String
    @Binding private var isOn: Bool
    private let accent: Color
    private let clearGlass: Bool

    public init(_ title: String, isOn: Binding<Bool>, accent: Color, clearGlass: Bool) {
        self.title = title
        _isOn = isOn
        self.accent = accent
        self.clearGlass = clearGlass
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(TrackerGlassToggleStyle(accent: accent, clearGlass: clearGlass))
                .accessibilityLabel(Text(title))
        }
    }
}

public struct TrackerSettingsFieldLabel: View {
    private let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
    }
}

public struct TrackerSettingsCaption: View {
    private let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct TrackerSettingsThresholdPicker: View {
    private let values: [Int]
    @Binding private var selection: Set<Int>
    private let accent: Color
    private let clearGlass: Bool

    public init(values: [Int], selection: Binding<Set<Int>>, accent: Color, clearGlass: Bool) {
        self.values = values
        _selection = selection
        self.accent = accent
        self.clearGlass = clearGlass
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { value in
                let isSelected = selection.contains(value)
                Button {
                    if isSelected { selection.remove(value) }
                    else { selection.insert(value) }
                } label: {
                    Text("\(value)%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundColor(isSelected ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .modifier(TrackerGlassChoice(isSelected: isSelected, accent: accent, clearGlass: clearGlass))
                .help(isSelected ? "Click to stop notifying at \(value)%" : "Click to notify at \(value)%")
            }
        }
    }
}

public struct TrackerSettingsFooter<Status: View>: View {
    private let accent: Color
    private let testTitle: String
    private let testDisabled: Bool
    private let saveDisabled: Bool
    private let onTest: () -> Void
    private let onCancel: () -> Void
    private let onSave: () -> Void
    private let status: Status

    public init(
        accent: Color,
        testTitle: String,
        testDisabled: Bool = false,
        saveDisabled: Bool = false,
        onTest: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSave: @escaping () -> Void,
        @ViewBuilder status: () -> Status
    ) {
        self.accent = accent
        self.testTitle = testTitle
        self.testDisabled = testDisabled
        self.saveDisabled = saveDisabled
        self.onTest = onTest
        self.onCancel = onCancel
        self.onSave = onSave
        self.status = status()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            status
            HStack {
                Button(testTitle, action: onTest)
                    .trackerGhostButton()
                    .disabled(testDisabled)
                Spacer()
                Button("Cancel", action: onCancel).trackerGhostButton()
                Button("Save", action: onSave)
                    .trackerPrimaryButton(accent: accent)
                    .disabled(saveDisabled)
            }
        }
        .padding(16)
    }
}

public extension View {
    func trackerSettingsCardStack(spacing: CGFloat = 16) -> some View {
        trackerGlassContainer(spacing: spacing)
    }

    func trackerMenuCardLayout() -> some View {
        padding(14).frame(maxWidth: .infinity, alignment: .leading)
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
