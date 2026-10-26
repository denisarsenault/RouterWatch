//
//  RouterWatchIntents.swift
//  RouterWatch
//

import AppIntents
import Foundation

// MARK: - Run a speed test

/// "Hey Siri, run a speed test." Also the piece a shortcut uses to measure on
/// demand — when joining a Wi-Fi network, say, or before a video call.
struct RunSpeedTestIntent: AppIntent {

    static var title: LocalizedStringResource = "Run Speed Test"

    static var description: IntentDescription {
        IntentDescription(
            "Measures download, upload, and latency against a test server outside your network, and records the result in that network's log.",
            categoryName: "Testing",
            searchKeywords: ["speed", "bandwidth", "internet", "download", "upload", "latency"]
        )
    }

    /// The test takes several seconds and needs no interface, so it runs
    /// without dragging the app to the front.
    static var openAppWhenRun: Bool = false

    static var parameterSummary: some ParameterSummary {
        Summary("Run a speed test")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let environment = IntentContext.preparedEnvironment()
        let result = await environment.monitor.probeOnce()
        let network = environment.networks.profile(id: result.networkID)?.displayName

        // A failed test is a real answer to "how fast is my connection", so it
        // comes back as zero with an explanation rather than as an error that
        // would abort the surrounding shortcut.
        guard let download = result.downloadMbps else {
            let reason = result.errorKind?.title ?? "the test did not complete"
            return .result(
                value: 0,
                dialog: IntentDialog("No connection\(network.map { " on \($0)" } ?? ""): \(reason).")
            )
        }

        var summary = "\(Format.mbps(download)) down"
        if let upload = result.uploadMbps {
            summary += ", \(Format.mbps(upload)) up"
        }
        if let latency = result.latencyMs {
            summary += ", \(Format.milliseconds(latency))"
        }
        if let network {
            summary += " on \(network)"
        }
        return .result(value: download, dialog: IntentDialog("\(summary).") )
    }
}

// MARK: - Current status

/// Answers "is my internet working?" from the last recorded test, without
/// spending bandwidth on a new one.
struct GetConnectionStatusIntent: AppIntent {

    static var title: LocalizedStringResource = "Get Connection Status"

    static var description: IntentDescription {
        IntentDescription(
            "Reports whether the connection is working, based on the most recent test. Does not run a new test.",
            categoryName: "Status",
            searchKeywords: ["status", "outage", "down", "internet"]
        )
    }

    static var openAppWhenRun: Bool = false

    static var parameterSummary: some ParameterSummary {
        Summary("Get the current connection status")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let environment = IntentContext.preparedEnvironment()
        let health = environment.monitor.health
        let network = environment.networks.activeProfile?.displayName

        guard let last = environment.networks.activeStore.lastResult else {
            return .result(value: health.title, dialog: IntentDialog("No tests have run yet."))
        }

        var sentence = health.title
        if let network {
            sentence += " on \(network)"
        }
        if let outageStart = environment.monitor.outageStartedAt {
            sentence += ", down for \(Format.duration(Date().timeIntervalSince(outageStart)))"
        } else if let download = last.downloadMbps {
            sentence += ", last test \(Format.mbps(download)) down \(Format.relative(last.timestamp))"
        }
        return .result(value: health.title, dialog: IntentDialog("\(sentence).") )
    }
}

// MARK: - Statistics

/// Summarises a network's log — the number worth quoting at an ISP.
struct GetNetworkStatisticsIntent: AppIntent {

    static var title: LocalizedStringResource = "Get Network Statistics"

    static var description: IntentDescription {
        IntentDescription(
            "Summarises recorded tests for a network: availability, median download speed, and how many tests failed.",
            categoryName: "Status",
            searchKeywords: ["statistics", "availability", "uptime", "median", "errors"]
        )
    }

    static var openAppWhenRun: Bool = false

    @Parameter(title: "Time Range", default: TimeRange.hour24)
    var range: TimeRange

    @Parameter(title: "Network", description: "Leave empty for the network this device is on now.")
    var network: NetworkEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get statistics for \(\.$range)") {
            \.$network
        }
    }

    /// - Returns: Availability as a percentage, the figure an ISP conversation
    ///   turns on. The dialog carries the rest.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let environment = IntentContext.preparedEnvironment()

        let profile: NetworkProfile?
        if let network {
            profile = environment.networks.profile(id: network.id)
        } else {
            profile = environment.networks.activeProfile
        }

        guard let profile else {
            return .result(value: 0, dialog: IntentDialog("RouterWatch has not identified a network yet."))
        }

        let store = environment.networks.store(for: profile.id)
        let stats = store.stats(in: range)
        guard stats.sampleCount > 0 else {
            return .result(
                value: 0,
                dialog: IntentDialog("No tests recorded for \(profile.displayName) in that period.")
            )
        }

        let availability = stats.availability * 100
        var sentence = "\(profile.displayName): \(Format.percent(stats.availability)) available"
        if let median = stats.medianDownloadMbps {
            sentence += ", median \(Format.mbps(median))"
        }
        sentence += ", \(stats.failureCount) of \(stats.sampleCount) tests failed"
        if let worst = stats.worstError {
            sentence += " (mostly \(worst.kind.title))"
        }
        return .result(value: availability, dialog: IntentDialog("\(sentence).") )
    }
}

// MARK: - Pause and resume

/// For automations: stop testing while tethered or travelling, resume at home.
struct SetMonitoringIntent: AppIntent {

    static var title: LocalizedStringResource = "Set Monitoring"

    static var description: IntentDescription {
        IntentDescription(
            "Turns scheduled testing on or off. Useful for pausing tests on a metered connection.",
            categoryName: "Settings",
            searchKeywords: ["pause", "resume", "monitoring", "schedule"]
        )
    }

    static var openAppWhenRun: Bool = false

    @Parameter(title: "Monitoring", default: true)
    var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set RouterWatch monitoring to \(\.$enabled)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let environment = IntentContext.preparedEnvironment()
        environment.monitor.setMonitoring(enabled: enabled)
        return .result(
            dialog: IntentDialog(enabled ? "Monitoring resumed." : "Monitoring paused.")
        )
    }
}
