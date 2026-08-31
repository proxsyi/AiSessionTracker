import SwiftUI

/// Both pingers render the same controls in the same order.
public struct TrackerPingAlertSettings: View {
    @Binding var failures: Bool
    @Binding var available: Bool
    @Binding var sent: Bool
    @Binding var scheduled: Bool
    let accent: Color
    let clearGlass: Bool

    public init(failures: Binding<Bool>, available: Binding<Bool>, sent: Binding<Bool>, scheduled: Binding<Bool>, accent: Color, clearGlass: Bool) {
        _failures = failures; _available = available; _sent = sent; _scheduled = scheduled
        self.accent = accent
        self.clearGlass = clearGlass
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TrackerSettingsToggleRow("Ping failures", isOn: $failures, accent: accent, clearGlass: clearGlass)
            TrackerSettingsToggleRow("New session available", isOn: $available, accent: accent, clearGlass: clearGlass)
            TrackerSettingsToggleRow("Ping sent", isOn: $sent, accent: accent, clearGlass: clearGlass)
                .help("Confirms a reply. Sending a ping does not necessarily begin a new usage window.")
            TrackerSettingsToggleRow("Scheduled ping sent", isOn: $scheduled, accent: accent, clearGlass: clearGlass)
                .help("One success alert per scheduled or automatic ping, never duplicate success alerts.")
        }
    }
}
