import SwiftUI

public enum TrackerScheduleRules {
    public static func validationMessage(_ slots: [TrackerScheduleTime]) -> String? {
        guard !slots.isEmpty else { return "Add at least one scheduled session." }
        guard slots.allSatisfy({ (0...23).contains($0.hour) && (0...59).contains($0.minute) }) else {
            return "Choose a valid time for every scheduled session."
        }
        let minutes = slots.map { $0.hour * 60 + $0.minute }.sorted()
        for index in minutes.indices {
            let next = index == minutes.count - 1 ? minutes[0] + 1440 : minutes[index + 1]
            if next - minutes[index] < 300 { return "Scheduled sessions must be at least 5 hours apart, including overnight." }
        }
        return nil
    }

    public static func firstAvailableTime(addingTo slots: [TrackerScheduleTime]) -> TrackerScheduleTime? {
        for minute in stride(from: 0, to: 1440, by: 1) {
            let time = TrackerScheduleTime(hour: minute / 60, minute: minute % 60)
            if validationMessage(slots + [time]) == nil { return time }
        }
        return nil
    }
}

public struct TrackerScheduleEditor: View {
    @Binding private var slots: [TrackerScheduleTime]
    private let accent: Color

    public init(slots: Binding<[TrackerScheduleTime]>, accent: Color) {
        _slots = slots
        self.accent = accent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TrackerSettingsFieldLabel("Schedule")
            ForEach(slots.indices, id: \.self) { index in
                HStack {
                    DatePicker("Scheduled time", selection: timeBinding(index), displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.stepperField).controlSize(.small)
                        .accessibilityLabel("Scheduled time \(index + 1)")
                    Spacer()
                    Button { slots.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                        .disabled(slots.count <= 1).help("Remove time")
                        .accessibilityLabel("Remove scheduled time \(index + 1)")
                }
            }
            Button("Add time") {
                if let next = TrackerScheduleRules.firstAvailableTime(addingTo: slots) { slots.append(next) }
            }
            .buttonStyle(.plain).foregroundColor(accent)
            .disabled(TrackerScheduleRules.firstAvailableTime(addingTo: slots) == nil)
            if let message = TrackerScheduleRules.validationMessage(slots) {
                Text(message).font(.system(size: 11)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("Scheduled pings must be at least five hours apart, including overnight.")
    }

    private func timeBinding(_ index: Int) -> Binding<Date> {
        Binding(get: {
            guard slots.indices.contains(index) else { return Date() }
            return Calendar.current.date(bySettingHour: slots[index].hour, minute: slots[index].minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            guard slots.indices.contains(index) else { return }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            slots[index] = TrackerScheduleTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        })
    }
}
