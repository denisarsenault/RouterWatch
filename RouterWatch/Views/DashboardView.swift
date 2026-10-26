//
//  DashboardView.swift
//  RouterWatch
//

import SwiftUI

struct DashboardView: View {

    @Environment(AppEnvironment.self) private var model
    @State private var range: TimeRange = .hour24

    private var stats: MonitorStats { model.store.stats(in: range) }
    private var results: [ProbeResult] { model.store.results(in: range) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    NetworkPicker()
                    Spacer(minLength: 0)
                }
                OtherNetworkBanner()
                statusCard
                latestReadings
                tiles
                chartSection
                worstErrorSection
            }
            .padding()
        }
        .navigationTitle("Dashboard")
    }

    // MARK: Status

    private var statusCard: some View {
        let health = model.monitor.health
        return HStack(alignment: .center, spacing: 16) {
            Image(systemName: health.symbolName)
                .font(.system(size: 34))
                .foregroundStyle(health.tint)
                .frame(width: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(health.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    model.monitor.runNow()
                } label: {
                    Label("Test Now", systemImage: "arrow.clockwise")
                }
                .disabled(model.monitor.activity.isProbing)

                // `.switch` is unavailable on tvOS, where Toggle already
                // renders as a focusable row.
                #if os(tvOS)
                Toggle("Monitoring", isOn: monitoringBinding)
                #else
                Toggle("Monitoring", isOn: monitoringBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Monitoring enabled")
                #endif
            }
        }
        .padding(16)
        .background(health.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(health.tint.opacity(0.35), lineWidth: 1)
        )
    }

    private var monitoringBinding: Binding<Bool> {
        Binding(
            get: { model.settings.isMonitoringEnabled },
            set: { model.monitor.setMonitoring(enabled: $0) }
        )
    }

    private var statusDetail: String {
        switch model.monitor.activity {
        case .probing:
            return "Running a test against \(model.settings.activeEndpoint.name)…"
        case .stopped:
            return "Monitoring is off. Turn it back on to resume scheduled tests."
        case .waiting:
            if let outageStart = model.monitor.outageStartedAt {
                let since = "Down since \(Format.shortTime(outageStart)) (\(Format.duration(Date().timeIntervalSince(outageStart))))"
                if !model.pathMonitor.isSatisfied {
                    return since + " · this device is offline; will test as soon as it reconnects"
                }
                return since + " · checking for recovery every \(Int(model.monitor.recoveryCheckInterval)) seconds"
            }
            var parts: [String] = []
            if let network = model.networks.activeProfile {
                parts.append("On \(network.displayName)")
            }
            if let last = model.networks.activeStore.lastResult {
                parts.append("Last test \(Format.relative(last.timestamp))")
            }
            parts.append("next in \(Format.countdown(model.monitor.secondsUntilNextRun))")
            if !model.pathMonitor.isSatisfied {
                parts.append("this device is offline")
            } else {
                parts.append("on \(model.pathMonitor.interface.title)")
            }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Latest readings

    private var latestReadings: some View {
        let last = model.store.lastResult
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Latest Test",
                subtitle: last.map { Format.timestamp($0.timestamp) } ?? "No tests recorded yet"
            )
            StatTileGrid {
                StatTile(
                    title: "Download",
                    value: Format.mbps(last?.downloadMbps),
                    caption: last.map { Format.bytes($0.bytesDownloaded) + " transferred" },
                    symbolName: "arrow.down.circle",
                    tint: .accentColor
                )
                StatTile(
                    title: "Upload",
                    value: Format.mbps(last?.uploadMbps),
                    caption: model.settings.measuresUpload ? nil : "Disabled in Settings",
                    symbolName: "arrow.up.circle",
                    tint: .purple
                )
                StatTile(
                    title: "Latency",
                    value: Format.milliseconds(last?.latencyMs),
                    caption: last?.jitterMs.map { "± \(Format.milliseconds($0)) jitter" },
                    symbolName: "timer",
                    tint: .teal
                )
            }

            if let last, let kind = last.errorKind {
                HStack(alignment: .top, spacing: 10) {
                    ErrorBadge(kind: kind)
                    Text(last.errorDetail ?? kind.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Aggregates

    private var tiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Summary") {
                TimeRangePicker(range: $range)
            }
            StatTileGrid {
                StatTile(
                    title: "Availability",
                    value: stats.sampleCount == 0 ? "—" : Format.percent(stats.availability),
                    caption: "\(stats.outageCount) outage\(stats.outageCount == 1 ? "" : "s") of \(stats.sampleCount)",
                    symbolName: "checkmark.shield",
                    tint: stats.availability >= 0.99 ? .green : .orange
                )
                StatTile(
                    title: "Median Download",
                    value: Format.mbps(stats.medianDownloadMbps),
                    caption: "min \(Format.mbps(stats.minDownloadMbps)) · max \(Format.mbps(stats.maxDownloadMbps))",
                    symbolName: "chart.bar",
                    tint: .accentColor
                )
                StatTile(
                    title: "Avg Latency",
                    value: Format.milliseconds(stats.averageLatencyMs),
                    caption: stats.averageJitterMs.map { "± \(Format.milliseconds($0)) jitter" },
                    symbolName: "timer",
                    tint: .teal
                )
                StatTile(
                    title: "Errors",
                    value: "\(stats.failureCount)",
                    caption: stats.worstError.map { "mostly \($0.kind.title)" } ?? "none recorded",
                    symbolName: "exclamationmark.triangle",
                    tint: stats.failureCount == 0 ? .green : .red
                )
            }
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Throughput",
                subtitle: "Red lines mark probes where no data moved at all"
            )
            ThroughputChartView(
                results: results,
                thresholdMbps: model.settings.lowThroughputThresholdMbps,
                showsUpload: model.settings.measuresUpload
            )
        }
    }

    @ViewBuilder
    private var worstErrorSection: some View {
        if let worst = stats.worstError {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Most Common Problem")
                HStack(alignment: .top, spacing: 12) {
                    ErrorBadge(kind: worst.kind)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(worst.count) of \(stats.failureCount) failures in the last \(range.title.lowercased())")
                            .font(.callout)
                        Text(worst.kind.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}
