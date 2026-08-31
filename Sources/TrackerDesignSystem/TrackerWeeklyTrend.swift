import Charts
import SwiftUI

public struct TrackerWeeklyTrend: View {
    let title: String
    let points: [TrackerUsageHistoryPoint]
    let color: Color

    public init(title: String, points: [TrackerUsageHistoryPoint], color: Color) {
        self.title = title; self.points = points; self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TrackerSectionHeader(text: title)
            if points.count < 2 {
                Text("The chart will appear after another refresh.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                Chart(points) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Usage", point.percent), series: .value("Weekly window", point.series))
                        .foregroundStyle(color.opacity(0.18))
                    LineMark(x: .value("Time", point.date), y: .value("Usage", point.percent), series: .value("Weekly window", point.series))
                        .foregroundStyle(color)
                }
                .chartYScale(domain: 0...100).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 54)
            }
            Text("Server-reported weekly percentage · sampled locally while running")
                .font(.system(size: 9)).foregroundColor(.secondary)
        }
    }
}
