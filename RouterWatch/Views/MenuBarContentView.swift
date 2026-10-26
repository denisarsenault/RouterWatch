//
//  MenuBarContentView.swift
//  RouterWatch
//

#if os(macOS)

import Charts
import SwiftUI

/// The panel that drops out of the menu bar icon.
///
/// Deliberately a summary, not a second dashboard: current state, the last
/// reading, the day's failures as a compact bar chart, and the three actions
/// worth taking without opening a window.
struct MenuBarContentView: View {

    @Environment(AppEnvironment.self) private var model
    @Environment(\.openWindow) private var openWindow

    // The menu bar always describes the network the Mac is on right now,
    // whatever network the main window happens to be showing.
    private var tallies: [ErrorTally] { model.networks.activeStore.errorTallies(in: .hour24) }
    private var stats: MonitorStats { model.networks.activeStore.stats(in: .hour24) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            readings
            Divider()
            errorChart
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.monitor.health.symbolName)
                .font(.title2)
                .foregroundStyle(model.monitor.health.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.monitor.health.title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let network = model.networks.activeProfile {
                    Label(network.displayName, systemImage: "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        switch model.monitor.activity {
        case .probing: return "Testing…"
        case .stopped: return "Paused"
        case .waiting:
            if let outageStart = model.monitor.outageStartedAt {
                return "Down \(Format.duration(Date().timeIntervalSince(outageStart))) · watching for recovery"
            }
            return "Next test in \(Format.countdown(model.monitor.secondsUntilNextRun))"
        }
    }

    // MARK: Readings

    private var readings: some View {
        let last = model.networks.activeStore.lastResult
        return VStack(alignment: .leading, spacing: 8) {
            reading("Download", Format.mbps(last?.downloadMbps), "arrow.down.circle")
            reading("Upload", Format.mbps(last?.uploadMbps), "arrow.up.circle")
            reading("Latency", Format.milliseconds(last?.latencyMs), "timer")
            reading("Availability, 24h", Format.percent(stats.availability), "checkmark.shield")
        }
    }

    private func reading(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.callout)
            Spacer(minLength: 8)
            Text(value)
                .font(.callout)
                .monospacedDigit()
                .fontWeight(.medium)
        }
    }

    // MARK: Errors

    @ViewBuilder
    private var errorChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Errors, last 24 hours")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Fixed height, whatever the data. `MenuBarExtra` sizes its panel
            // to the content, so a chart that grew when a new error type
            // arrived would resize the open panel mid-layout — which AppKit
            // reports as layout recursion — and make the panel jump.
            Group {
                if chartTallies.isEmpty {
                    Label("No failures recorded", systemImage: "checkmark.seal")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Chart(chartTallies) { tally in
                        BarMark(
                            x: .value("Failures", tally.count),
                            y: .value("Type", tally.kind.title)
                        )
                        .foregroundStyle(tally.kind.tint)
                        .cornerRadius(3)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("\(tally.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartYScale(domain: chartTallies.map(\.kind.title))
                    .chartXAxis(.hidden)
                }
            }
            .frame(height: Self.chartHeight, alignment: .topLeading)

            if tallies.count > Self.maxChartRows {
                Text("+\(tallies.count - Self.maxChartRows) more types — open the dashboard for all")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let maxChartRows = 4
    private static let chartHeight = CGFloat(maxChartRows) * 26 + 10

    private var chartTallies: [ErrorTally] { Array(tallies.prefix(Self.maxChartRows)) }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 6) {
            Button {
                model.monitor.runNow()
            } label: {
                Label("Test Now", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.monitor.activity.isProbing)

            Button {
                model.monitor.setMonitoring(enabled: !model.settings.isMonitoringEnabled)
            } label: {
                Label(
                    model.settings.isMonitoringEnabled ? "Pause Monitoring" : "Resume Monitoring",
                    systemImage: model.settings.isMonitoringEnabled ? "pause.circle" : "play.circle"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                // Bring the app forward first: in menu-bar-only mode the window
                // would otherwise open behind whatever the user is working in.
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: AppEnvironment.mainWindowID)
            } label: {
                Label("Open Dashboard…", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit RouterWatch", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
    }
}

#endif
