//
//  SettingsStore.swift
//  RouterWatch
//

import Foundation
import Observation

/// User preferences, stored in `UserDefaults`.
///
/// Every property reads and writes `UserDefaults` directly through the
/// `access` / `withMutation` hooks the `@Observable` macro generates. That is
/// the supported way to put custom storage behind an observable property —
/// stored properties with `didSet` observers are not allowed under the macro,
/// and this shape has the nicer property that there is no in-memory copy to
/// drift out of sync with what is on disk.
@MainActor
@Observable
final class SettingsStore {

    // MARK: Fixed choice sets
    //
    // Offered as fixed sets rather than free entry so every platform can use a
    // picker — tvOS has no `Stepper` and typing numbers on a TV remote is a
    // poor experience.

    static let intervalChoices = [1, 5, 10, 15, 30, 60, 120]
    /// Capped at 50 MB: Cloudflare refuses 100 MB requests outright, and
    /// public test servers throttle networks that pull large payloads often.
    static let downloadSizeChoices = [5, 10, 25, 50]
    static let uploadSizeChoices = [1, 5, 10, 25]
    static let throughputThresholdChoices: [Double] = [0, 1, 5, 10, 25, 50, 100, 250, 500]
    static let latencyThresholdChoices: [Double] = [50, 100, 150, 250, 500, 1000]
    static let retentionChoices = [7, 30, 90, 365]

    // MARK: Schedule

    var intervalMinutes: Int {
        get { access(keyPath: \.intervalMinutes); return defaults.integer(forKey: Key.intervalMinutes) }
        set { withMutation(keyPath: \.intervalMinutes) { defaults.set(newValue, forKey: Key.intervalMinutes) } }
    }

    var intervalSeconds: TimeInterval { TimeInterval(intervalMinutes * 60) }

    var isMonitoringEnabled: Bool {
        get { access(keyPath: \.isMonitoringEnabled); return defaults.bool(forKey: Key.isMonitoringEnabled) }
        set { withMutation(keyPath: \.isMonitoringEnabled) { defaults.set(newValue, forKey: Key.isMonitoringEnabled) } }
    }

    // MARK: Endpoint

    var endpointID: String {
        get { access(keyPath: \.endpointID); return defaults.string(forKey: Key.endpointID) ?? TestEndpoint.cloudflare.id }
        set { withMutation(keyPath: \.endpointID) { defaults.set(newValue, forKey: Key.endpointID) } }
    }

    var customDownloadURLString: String {
        get { access(keyPath: \.customDownloadURLString); return defaults.string(forKey: Key.customDownloadURL) ?? "" }
        set { withMutation(keyPath: \.customDownloadURLString) { defaults.set(newValue, forKey: Key.customDownloadURL) } }
    }

    /// The endpoint the engine should use right now, custom URL included.
    var activeEndpoint: TestEndpoint {
        if endpointID == TestEndpoint.customIdentifier {
            return .custom(downloadURLString: customDownloadURLString)
        }
        return TestEndpoint.presets.first { $0.id == endpointID } ?? .cloudflare
    }

    // MARK: Payload sizes

    var downloadMegabytes: Int {
        get {
            access(keyPath: \.downloadMegabytes)
            // Older builds offered 100 MB; clamp so the picker still has a match.
            return min(defaults.integer(forKey: Key.downloadMegabytes), SettingsStore.downloadSizeChoices.last ?? 50)
        }
        set { withMutation(keyPath: \.downloadMegabytes) { defaults.set(newValue, forKey: Key.downloadMegabytes) } }
    }

    var uploadMegabytes: Int {
        get { access(keyPath: \.uploadMegabytes); return defaults.integer(forKey: Key.uploadMegabytes) }
        set { withMutation(keyPath: \.uploadMegabytes) { defaults.set(newValue, forKey: Key.uploadMegabytes) } }
    }

    var measuresUpload: Bool {
        get { access(keyPath: \.measuresUpload); return defaults.bool(forKey: Key.measuresUpload) }
        set { withMutation(keyPath: \.measuresUpload) { defaults.set(newValue, forKey: Key.measuresUpload) } }
    }

    var measuresLatency: Bool {
        get { access(keyPath: \.measuresLatency); return defaults.bool(forKey: Key.measuresLatency) }
        set { withMutation(keyPath: \.measuresLatency) { defaults.set(newValue, forKey: Key.measuresLatency) } }
    }

    // MARK: Thresholds

    var lowThroughputThresholdMbps: Double {
        get { access(keyPath: \.lowThroughputThresholdMbps); return defaults.double(forKey: Key.lowThroughputThreshold) }
        set { withMutation(keyPath: \.lowThroughputThresholdMbps) { defaults.set(newValue, forKey: Key.lowThroughputThreshold) } }
    }

    var highLatencyThresholdMs: Double {
        get { access(keyPath: \.highLatencyThresholdMs); return defaults.double(forKey: Key.highLatencyThreshold) }
        set { withMutation(keyPath: \.highLatencyThresholdMs) { defaults.set(newValue, forKey: Key.highLatencyThreshold) } }
    }

    // MARK: Retention and alerts

    var retentionDays: Int {
        get { access(keyPath: \.retentionDays); return defaults.integer(forKey: Key.retentionDays) }
        set { withMutation(keyPath: \.retentionDays) { defaults.set(newValue, forKey: Key.retentionDays) } }
    }

    var notifiesOnFailure: Bool {
        get { access(keyPath: \.notifiesOnFailure); return defaults.bool(forKey: Key.notifiesOnFailure) }
        set { withMutation(keyPath: \.notifiesOnFailure) { defaults.set(newValue, forKey: Key.notifiesOnFailure) } }
    }

    // MARK: macOS behaviour

    var launchesAtLogin: Bool {
        get { access(keyPath: \.launchesAtLogin); return defaults.bool(forKey: Key.launchesAtLogin) }
        set { withMutation(keyPath: \.launchesAtLogin) { defaults.set(newValue, forKey: Key.launchesAtLogin) } }
    }

    /// Menu-bar-only mode. Applied at runtime through the activation policy
    /// rather than a static `LSUIElement`, so one build can do both and the
    /// user can change their mind without reinstalling.
    var hidesDockIcon: Bool {
        get { access(keyPath: \.hidesDockIcon); return defaults.bool(forKey: Key.hidesDockIcon) }
        set { withMutation(keyPath: \.hidesDockIcon) { defaults.set(newValue, forKey: Key.hidesDockIcon) } }
    }

    var showsSpeedInMenuBar: Bool {
        get { access(keyPath: \.showsSpeedInMenuBar); return defaults.bool(forKey: Key.showsSpeedInMenuBar) }
        set { withMutation(keyPath: \.showsSpeedInMenuBar) { defaults.set(newValue, forKey: Key.showsSpeedInMenuBar) } }
    }

    // MARK: Derived

    var downloadBytes: Int { downloadMegabytes * 1_000_000 }
    var uploadBytes: Int { uploadMegabytes * 1_000_000 }

    /// Generous enough for a slow line to finish a large payload, short enough
    /// that a dead link gets logged promptly instead of hanging the schedule.
    var requestTimeout: TimeInterval { 60 }

    func makeProbeConfiguration() -> ProbeConfiguration {
        let endpoint = activeEndpoint
        // The other preset is the fallback. A custom URL falls back to CacheFly.
        let fallback: TestEndpoint = endpoint.id == TestEndpoint.cachefly.id ? .cloudflare : .cachefly
        return ProbeConfiguration(
            endpoint: endpoint,
            fallbackEndpoint: fallback,
            downloadBytes: endpoint.fixedDownloadBytes ?? downloadBytes,
            uploadBytes: uploadBytes,
            measuresUpload: measuresUpload && endpoint.supportsUpload,
            measuresLatency: measuresLatency,
            latencySampleCount: 4,
            requestTimeout: requestTimeout,
            lowThroughputThresholdMbps: lowThroughputThresholdMbps,
            highLatencyThresholdMs: highLatencyThresholdMs
        )
    }

    // MARK: Storage

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.intervalMinutes: 15,
            Key.isMonitoringEnabled: true,
            Key.endpointID: TestEndpoint.cloudflare.id,
            Key.customDownloadURL: "",
            Key.downloadMegabytes: 25,
            Key.uploadMegabytes: 5,
            Key.measuresUpload: true,
            Key.measuresLatency: true,
            Key.lowThroughputThreshold: 10.0,
            Key.highLatencyThreshold: 250.0,
            Key.retentionDays: 90,
            Key.notifiesOnFailure: true,
            Key.launchesAtLogin: false,
            Key.hidesDockIcon: false,
            Key.showsSpeedInMenuBar: true
        ])
    }

    private enum Key {
        static let intervalMinutes = "intervalMinutes"
        static let isMonitoringEnabled = "isMonitoringEnabled"
        static let endpointID = "endpointID"
        static let customDownloadURL = "customDownloadURL"
        static let downloadMegabytes = "downloadMegabytes"
        static let uploadMegabytes = "uploadMegabytes"
        static let measuresUpload = "measuresUpload"
        static let measuresLatency = "measuresLatency"
        static let lowThroughputThreshold = "lowThroughputThresholdMbps"
        static let highLatencyThreshold = "highLatencyThresholdMs"
        static let retentionDays = "retentionDays"
        static let notifiesOnFailure = "notifiesOnFailure"
        static let launchesAtLogin = "launchesAtLogin"
        static let hidesDockIcon = "hidesDockIcon"
        static let showsSpeedInMenuBar = "showsSpeedInMenuBar"
    }
}
