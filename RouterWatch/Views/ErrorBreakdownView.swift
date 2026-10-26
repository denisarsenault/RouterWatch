//
//  ErrorBreakdownView.swift
//  RouterWatch
//

import Charts
import SwiftUI

/// One stacked segment: how many failures of a given kind happened in a given
/// time bucket.
struct ErrorBucket: Identifiable {
    let bucketStart: Date
    let kind: ErrorKind
    let count: Int
    var id: String { "\(bucketStart.timeIntervalSince1970)-\(kind.rawValue)" }
}

/// The error bar graph: what went wrong, how often, and when.
///
/// Two views of the same failures. "By type" is a horizontal bar per error kind
/// — horizontal because the category names are words, and words read badly
/// rotated under a vertical axis. "Over time" stacks the same counts into
/// hourly or daily buckets, which is what turns "it breaks sometimes" into
/// "it breaks every evening".
struct ErrorBreakdownView: View {

    @Environment(AppEnvironment.self) private var model
    @State private var range: TimeRange = .days7
    @State private var mode: Mode = .byType

    enum Mode: String, CaseIterable, Identifiable {
        case byType
        case overTime
        var id: String { rawValue }
        var title: String { self == .byType ? "By Type" : "Over Time" }
    }

    private var results: [ProbeResult] { model.store.results(in: range) }
    private var tallies: [ErrorTally] { MonitorStats.tally(results) }
    private var totalFailures: Int { tallies.reduce(0) { $0 + $1.count } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if tallies.isEmpty {
                    EmptyStateView(
                        symbolName: "checkmark.seal",
                        title: "No errors recorded",
                        message: "Nothing failed in the last \(range.title.lowercased()). The chart fills in as problems occur."
                    )
                } else {
                    switch mode {
                    case .byType: byTypeChart
                    case .overTime: overTimeChart
                    }
                    legend
                }
            }
            .padding()
        }
        .navigationTitle("Errors")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "Error Breakdown",
                subtitle: "\(totalFailures) failed \(totalFailures == 1 ? "probe" : "probes") of \(results.count) in the last \(range.title.lowercased())"
            )

            HStack(spacing: 16) {
                NetworkPicker()
                TimeRangePicker(range: $range)
                Spacer(minLength: 0)
            }
            OtherNetworkBanner()

            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            #if !os(tvOS)
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            #endif
            .labelsHidden()
        }
    }

    // MARK: Charts

    private var byTypeChart: some View {
        Chart(tallies) { tally in
            BarMark(
                x: .value("Failures", tally.count),
                y: .value("Error Type", tally.kind.title)
            )
            .foregroundStyle(tally.kind.tint)
            .cornerRadius(5)
            .annotation(position: .trailing, alignment: .leading) {
                Text("\(tally.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        // Pinning the domain keeps bars in a stable order instead of letting
        // Charts re-sort them alphabetically on every refresh.
        .chartYScale(domain: tallies.map(\.kind.title))
        .chartXAxis {
            AxisMarks(position: .bottom) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let count = value.as(Int.self) {
                        Text("\(count)")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .frame(height: max(160, CGFloat(tallies.count) * barRowHeight + 48))
    }

    private var overTimeChart: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("When", bucket.bucketStart, unit: calendarUnit),
                y: .value("Failures", bucket.count)
            )
            .foregroundStyle(by: .value("Error Type", bucket.kind.title))
            .cornerRadius(3)
        }
        .chartForegroundStyleScale(styleScale)
        .chartLegend(position: .bottom, spacing: 12)
        .frame(height: 280)
    }

    /// Buckets failures by hour for a one-day window and by day beyond that, so
    /// the bars stay countable rather than collapsing into a smear.
    private var calendarUnit: Calendar.Component {
        range == .hour24 ? .hour : .day
    }

    private var buckets: [ErrorBucket] {
        let calendar = Calendar.current
        let component: Set<Calendar.Component> = calendarUnit == .hour
            ? [.year, .month, .day, .hour]
            : [.year, .month, .day]

        var counts: [String: ErrorBucket] = [:]
        for result in results {
            guard let kind = result.errorKind else { continue }
            let components = calendar.dateComponents(component, from: result.timestamp)
            guard let start = calendar.date(from: components) else { continue }
            let key = "\(start.timeIntervalSince1970)-\(kind.rawValue)"
            let existing = counts[key]?.count ?? 0
            counts[key] = ErrorBucket(bucketStart: start, kind: kind, count: existing + 1)
        }
        return counts.values.sorted { $0.bucketStart < $1.bucketStart }
    }

    /// Ties each series to the same colour its badge uses elsewhere.
    private var styleScale: KeyValuePairs<String, Color> {
        // KeyValuePairs cannot be built dynamically, so the mapping is spelled
        // out once here and mirrors `ErrorKind.tint`.
        [
            ErrorKind.noNetworkPath.title: ErrorKind.noNetworkPath.tint,
            ErrorKind.dnsFailure.title: ErrorKind.dnsFailure.tint,
            ErrorKind.cannotConnect.title: ErrorKind.cannotConnect.tint,
            ErrorKind.connectionLost.title: ErrorKind.connectionLost.tint,
            ErrorKind.timeout.title: ErrorKind.timeout.tint,
            ErrorKind.tlsFailure.title: ErrorKind.tlsFailure.tint,
            ErrorKind.httpError.title: ErrorKind.httpError.tint,
            ErrorKind.rateLimited.title: ErrorKind.rateLimited.tint,
            ErrorKind.lowThroughput.title: ErrorKind.lowThroughput.tint,
            ErrorKind.highLatency.title: ErrorKind.highLatency.tint,
            ErrorKind.cancelled.title: ErrorKind.cancelled.tint,
            ErrorKind.unknown.title: ErrorKind.unknown.tint
        ]
    }

    private var barRowHeight: CGFloat {
        #if os(tvOS)
        return 54
        #else
        return 34
        #endif
    }

    // MARK: Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "What these mean")
            ForEach(tallies) { tally in
                HStack(alignment: .top, spacing: 12) {
                    ErrorBadge(kind: tally.kind)
                        .frame(width: legendBadgeWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(tally.count) occurrences — \(share(of: tally)) of all failures")
                            .font(.caption)
                            .monospacedDigit()
                        Text(tally.kind.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var legendBadgeWidth: CGFloat {
        #if os(tvOS)
        return 260
        #else
        return 170
        #endif
    }

    private func share(of tally: ErrorTally) -> String {
        guard totalFailures > 0 else { return "0%" }
        return Format.percent(Double(tally.count) / Double(totalFailures))
    }
}
