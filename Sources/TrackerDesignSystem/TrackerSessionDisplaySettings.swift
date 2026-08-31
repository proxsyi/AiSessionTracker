import SwiftUI

public struct TrackerSessionDisplaySettings: View {
    @Binding var nextPossible: Bool
    @Binding var scheduled: Bool
    @Binding var focusScheduled: Bool
    @Binding var autoStart: Bool
    let accent: Color
    let clearGlass: Bool

    public init(nextPossible: Binding<Bool>, scheduled: Binding<Bool>, focusScheduled: Binding<Bool>, autoStart: Binding<Bool>, accent: Color, clearGlass: Bool) {
        _nextPossible = nextPossible
        _scheduled = scheduled
        _focusScheduled = focusScheduled
        _autoStart = autoStart
        self.accent = accent
        self.clearGlass = clearGlass
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TrackerSettingsToggleRow("Next possible session", isOn: $nextPossible, accent: accent, clearGlass: clearGlass,
                helpText: "Show when this provider's active five-hour window resets.")
            TrackerSettingsToggleRow("Scheduled session", isOn: $scheduled, accent: accent, clearGlass: clearGlass,
                helpText: "Show the next saved ping time, independently of the usage reset.")
            if nextPossible && scheduled {
                VStack(alignment: .leading, spacing: 6) {
                    TrackerSettingsFieldLabel("Main focus")
                    Picker("Main focus", selection: $focusScheduled) {
                        Text("Next possible").tag(false)
                        Text("Scheduled").tag(true)
                    }
                    .labelsHidden().pickerStyle(.menu).tint(accent)
                    .help("The other enabled countdown appears underneath in gray.")
                }
            }
            TrackerSettingsToggleRow("Start sessions when available", isOn: $autoStart, accent: accent, clearGlass: clearGlass,
                helpText: "Starts an available session unless a scheduled ping is due within five hours.")
        }
    }
}
