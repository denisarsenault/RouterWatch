//
//  ThroughputChartView.swift
//  RouterWatch
//

import Charts
import SwiftUI

/// Download speed over time, with failures called out.
///
/// Failed probes are drawn as full-height translucent bands rather than dropped
/// from the series. A speed chart that silently omits outages is flattering and
/// useless — the gaps are the story.
struct ThroughputChartView: View {

    let results: [ProbeResult]
    var thresholdMbps: Double
    var showsUpload: Bool = true

    private var successes: [ProbeResult] { results.filter { $0.downloadMbps != nil } }
    private var outages: [ProbeResult] { results.filter(\.isOutage) }

    private var peak: Double {
        let maxDownload = successes.compactMap(\.downloadMbps).max() ?? 0
        let maxUpload = showsUpload ? (successes.compactMap(\.uploadMbps).max() ?? 0) : 0
        return max(maxDownload, maxUpload, thresholdMbps, 1)
    }

    var body: some View {
        if results.isEmpty {
            EmptyStateView(
                symbolName: "chart.bar",
                title: "No measurements yet",
                message: "Results appear here after the first probe completes."
            )
        } else {
            // The bars need an explicit width: on a continuous time axis Charts
            // cannot infer one and logs a warning while guessing.
            GeometryReader { geometry in
                chart(barWidth: Self.barWidth(
                    for: successes.map(\.timestamp),
                    plotWidth: geometry.size.width - Self.yAxisAllowance
                ))
            }
            .frame(height: chartHeight)
        }
    }

    private func chart(barWidth: CGFloat) -> some View {
        Chart {
            ForEach(outages) { result in
                RuleMark(x: .value("Time", result.timestamp))
                    .foregroundStyle(.red.opacity(0.28))
                    .lineStyle(StrokeStyle(lineWidth: 3))
            }

            ForEach(successes) { result in
                BarMark(
                    x: .value("Time", result.timestamp),
                    y: .value("Download", result.downloadMbps ?? 0),
                    width: .fixed(barWidth)
                )
                .foregroundStyle(by: .value("Series", "Download"))
                .cornerRadius(2)
            }

            if showsUpload {
                ForEach(successes.filter { $0.uploadMbps != nil }) { result in
                    LineMark(
                        x: .value("Time", result.timestamp),
                        y: .value("Upload", result.uploadMbps ?? 0),
                        series: .value("Series", "Upload")
                    )
                    .foregroundStyle(by: .value("Series", "Upload"))
                    .interpolationMethod(.monotone)
                }
            }

            if thresholdMbps > 0 {
                RuleMark(y: .value("Floor", thresholdMbps))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Floor \(Format.mbps(thresholdMbps))")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
            }
        }
        .chartForegroundStyleScale(["Download": Color.accentColor, "Upload": Color.purple])
        .chartYScale(domain: 0...(peak * 1.15))
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartLegend(position: .bottom, spacing: 10)
    }

    /// Room the leading y-axis labels take from the plot area.
    static let yAxisAllowance: CGFloat = 40

    /// Width for one download bar: a share of the typical gap between probes,
    /// so neighbouring bars never overlap and never shrink to hairlines,
    /// whatever the test interval or time range.
    ///
    /// The median gap is used rather than the average so one long gap — the
    /// Mac asleep overnight — does not make every bar a sliver.
    static func barWidth(for timestamps: [Date], plotWidth: CGFloat) -> CGFloat {
        let widest: CGFloat = 14
        let narrowest: CGFloat = 1.5
        guard timestamps.count > 1, let first = timestamps.first, let last = timestamps.last else {
            return widest
        }
        let span = last.timeIntervalSince(first)
        guard span > 0, plotWidth > 0 else { return widest }

        let gaps = zip(timestamps.dropFirst(), timestamps)
            .map { $0.timeIntervalSince($1) }
            .sorted()
        let typicalGap = gaps[gaps.count / 2]
        let width = plotWidth * CGFloat(typicalGap / span) * 0.7
        return min(max(width, narrowest), widest)
    }

    private var chartHeight: CGFloat {
        #if os(tvOS)
        return 340
        #else
        return 240
        #endif
    }
}
