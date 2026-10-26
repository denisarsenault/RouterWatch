//
//  MonitorController.swift
//  RouterWatch
//

import Foundation
import Observation
import OSLog

#if os(macOS)
import AppKit
#endif

/// Overall health, as shown in the menu bar and at the top of the dashboard.
enum ConnectionHealth: Sendable {
    case unknown
    case healthy
    case degraded
    case down
    case paused

    var title: String {
        switch self {
        case .unknown: return "No Data Yet"
        case .healthy: return "Connection OK"
        case .degraded: return "Degraded"
        case .down: return "Connection Down"
        case .paused: return "Monitoring Paused"
        }
    }

    var symbolName: String {
        switch self {
        case .unknown: return "wifi.exclamationmark"
        case .healthy: return "wifi"
        case .degraded: return "wifi.exclamationmark"
        case .down: return "wifi.slash"
        case .paused: return "pause.circle"
        }
    }
}

/// What the monitor needs from a speed-test engine. A seam so the scheduling
/// and recovery logic can be tested without touching the network.
protocol ProbeRunning: Sendable {
    func run(configuration: ProbeConfiguration, interface: InterfaceKind, hasNetworkPath: Bool) async -> ProbeResult
    func isInternetReachable(configuration: ProbeConfiguration) async -> Bool
}

extension SpeedTestEngine: ProbeRunning {}

/// How often the monitor looks at things. Injected so tests can run the real
/// loop in milliseconds instead of seconds.
struct MonitorTiming: Sendable {
    /// How often the loop wakes to check whether anything is due.
    var tick: TimeInterval = 1
    /// While the connection is down, how often a cheap reachability check runs.
    var recoveryCheckInterval: TimeInterval = 20
    /// How long a lost network path must stay lost before a drop is recorded.
    /// Filters out the brief blips of a Wi-Fi roam.
    var pathDownSettle: TimeInterval = 3
    /// How long to wait after a network path returns before testing. DHCP and
    /// DNS usually need a few seconds after the interface itself comes up.
    var pathUpSettle: TimeInterval = 5
    /// Longest wait for the path monitor's first report before identifying
    /// the network anyway.
    var initialPathTimeout: TimeInterval = 3

    static let standard = MonitorTiming()
}

/// Drives the all-day schedule: runs a probe, records it, waits, repeats —
/// and, while the connection is down, watches for it to come back.
@MainActor
@Observable
final class MonitorController {

    enum Activity: Sendable {
        case stopped
        case waiting
        case probing

        var isProbing: Bool { self == .probing }
    }

    private(set) var activity: Activity = .stopped
    private(set) var nextRunDate: Date?
    private(set) var secondsUntilNextRun: TimeInterval = 0
    private(set) var probesThisSession = 0

    /// The most recent recorded test on the network this device is on.
    ///
    /// Read from the log rather than remembered from this session's probes, so
    /// a launch that never starts the monitor — an App Intent run by Shortcuts
    /// — still reports the connection truthfully instead of "no data yet".
    var lastResult: ProbeResult? { networks.activeStore.lastResult }

    /// When the ongoing outage began, or `nil` while the connection is up.
    var outageStartedAt: Date? { networks.activeStore.currentOutageStart() }

    var isOutage: Bool { lastResult?.isOutage == true }
    var recoveryCheckInterval: TimeInterval { timing.recoveryCheckInterval }

    var health: ConnectionHealth {
        // Paused is a decision the user made, not a side effect of whether the
        // loop happens to be running in this process.
        guard settings.isMonitoringEnabled else { return .paused }
        guard let lastResult else { return .unknown }
        guard let kind = lastResult.errorKind else { return .healthy }
        return kind.isHardFailure ? .down : .degraded
    }

    /// Short text for the menu bar item, e.g. "84" or "Down".
    func menuBarTitle(showsSpeed: Bool) -> String? {
        guard showsSpeed else { return nil }
        switch health {
        case .paused: return "Paused"
        case .down: return "Down"
        case .unknown: return nil
        case .healthy, .degraded:
            guard let mbps = lastResult?.downloadMbps else { return nil }
            return String(format: "%.0f", mbps)
        }
    }

    // MARK: Dependencies

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let networks: NetworkLibrary
    @ObservationIgnored private let identifier: NetworkIdentifying
    @ObservationIgnored private let pathMonitor: NetworkPathMonitor
    @ObservationIgnored private let notifications: NotificationService
    @ObservationIgnored private let engine: ProbeRunning
    @ObservationIgnored private let timing: MonitorTiming
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.mybrightzone.routerwatch",
        category: "Monitor"
    )

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var pathSettleTask: Task<Void, Never>?
    @ObservationIgnored private var networkSettleTask: Task<Void, Never>?
    @ObservationIgnored private var wantsImmediateRun = false
    @ObservationIgnored private var nextRecoveryCheckAt: Date?
    @ObservationIgnored private var inFlightProbe: Task<ProbeResult, Never>?
    /// Probes thrown away because the device changed networks mid-test.
    @ObservationIgnored private(set) var discardedProbeCount = 0
    #if os(macOS)
    @ObservationIgnored private var activityToken: NSObjectProtocol?
    #endif

    init(
        settings: SettingsStore,
        networks: NetworkLibrary,
        pathMonitor: NetworkPathMonitor,
        notifications: NotificationService,
        engine: ProbeRunning = SpeedTestEngine(),
        identifier: NetworkIdentifying = NetworkIdentifier(),
        timing: MonitorTiming = .standard
    ) {
        self.settings = settings
        self.networks = networks
        self.identifier = identifier
        self.pathMonitor = pathMonitor
        self.notifications = notifications
        self.engine = engine
        self.timing = timing

        pathMonitor.onAvailabilityChange = { [weak self] isAvailable in
            self?.pathAvailabilityChanged(isAvailable)
        }
        pathMonitor.onNetworkChange = { [weak self] in
            self?.networkChanged()
        }
    }

    // MARK: Lifecycle

    func start() {
        guard loopTask == nil else { return }
        beginBackgroundActivity()
        activity = .waiting

        // First probe fires immediately so the user sees a number right away
        // instead of staring at an empty dashboard for the first interval.
        wantsImmediateRun = true
        loopTask = Task { [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        pathSettleTask?.cancel()
        pathSettleTask = nil
        networkSettleTask?.cancel()
        networkSettleTask = nil
        activity = .stopped
        nextRunDate = nil
        secondsUntilNextRun = 0
        endBackgroundActivity()
    }

    func setMonitoring(enabled: Bool) {
        settings.isMonitoringEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// Asks the loop to probe on its next tick. Cheap and safe to call from a
    /// button; it never stacks up concurrent probes.
    func runNow() {
        if loopTask == nil {
            // Allow a one-off test even while monitoring is paused.
            Task { await probeOnce() }
            return
        }
        wantsImmediateRun = true
    }

    // MARK: The loop

    /// Ticks once a second and decides whether it is time to probe.
    ///
    /// Scheduling off an absolute `nextRunDate` rather than sleeping for the
    /// whole interval means a Mac that slept through three scheduled probes
    /// simply runs one when it wakes, instead of drifting further behind with
    /// every sleep cycle. It also gives the UI a live countdown for free.
    private func loop() async {
        while !Task.isCancelled {
            var due = wantsImmediateRun || (nextRunDate.map { Date() >= $0 } ?? true)

            if !due, await connectionHasReturned() {
                logger.notice("Reachability check succeeded during outage; testing now")
                due = true
            }

            if due {
                wantsImmediateRun = false
                await probeOnce()
                scheduleNextRun()
            }

            if let nextRunDate {
                secondsUntilNextRun = max(0, nextRunDate.timeIntervalSinceNow)
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(timing.tick * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    private func scheduleNextRun() {
        let next = Date().addingTimeInterval(settings.intervalSeconds)
        nextRunDate = next
        secondsUntilNextRun = max(0, next.timeIntervalSinceNow)
        activity = .waiting
    }

    // MARK: Recovery detection

    /// While the connection is down, runs a cheap reachability check every
    /// `recoveryCheckInterval` and reports whether the internet has come back.
    ///
    /// Without this a recovered connection would keep showing as down until
    /// the next scheduled test — up to two hours at the longest interval. A
    /// full speed test is too heavy to repeat every few seconds; a HEAD request
    /// costs a few hundred bytes.
    ///
    /// Skipped while the device has no network path at all: there is nothing
    /// to check, and the path monitor will announce the interface's return.
    private func connectionHasReturned() async -> Bool {
        guard isOutage, pathMonitor.isSatisfied else { return false }
        let now = Date()
        if let nextRecoveryCheckAt, now < nextRecoveryCheckAt { return false }
        nextRecoveryCheckAt = now.addingTimeInterval(timing.recoveryCheckInterval)
        return await engine.isInternetReachable(configuration: settings.makeProbeConfiguration())
    }

    /// Reacts to the device gaining or losing its network interface.
    ///
    /// Only acts when the change contradicts what the log currently says: the
    /// path returning during an outage triggers a test to confirm recovery,
    /// and the path dropping while the log says "up" records the outage
    /// immediately instead of at the next scheduled test. Both wait a few
    /// seconds first, so a Wi-Fi roam does not log a phantom outage and a
    /// rejoined network has time to get an address before it is tested.
    private func pathAvailabilityChanged(_ isAvailable: Bool) {
        guard loopTask != nil else { return }
        pathSettleTask?.cancel()

        let delay = isAvailable ? timing.pathUpSettle : timing.pathDownSettle
        pathSettleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.loopTask != nil else { return }
            // The path flipped back during the settle delay; nothing to do.
            guard self.pathMonitor.isSatisfied == isAvailable else { return }

            if isAvailable == self.isOutage {
                self.logger.notice("Network path \(isAvailable ? "returned" : "lost", privacy: .public); testing now")
                self.wantsImmediateRun = true
            }
        }
    }

    /// The device moved to a different router without going offline. Test the
    /// new network straight away, so its log starts with a baseline and the
    /// status stops describing the network that was left behind.
    private func networkChanged() {
        guard loopTask != nil else { return }
        networkSettleTask?.cancel()
        networkSettleTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.timing.pathUpSettle * 1_000_000_000))
            guard !Task.isCancelled, self.loopTask != nil else { return }
            self.logger.notice("Switched networks; testing now")
            self.wantsImmediateRun = true
        }
    }

    // MARK: Probing

    /// Runs one probe and records it. Used by the loop, the Test Now button,
    /// and the iOS background task.
    @discardableResult
    func probeOnce() async -> ProbeResult {
        // One probe at a time. A second request — the iOS background task
        // firing while the loop is mid-test — waits for the probe already
        // running instead of measuring alongside it and racing it to the log.
        if let inFlightProbe {
            return await inFlightProbe.value
        }
        let probe = Task { await self.performProbe() }
        inFlightProbe = probe
        let result = await probe.value
        inFlightProbe = nil
        return result
    }

    private func performProbe() async -> ProbeResult {
        activity = .probing
        defer { activity = loopTask != nil ? .waiting : .stopped }

        // Identifying the network before the path monitor has reported the
        // router would file this result under a router-less duplicate.
        await pathMonitor.waitForInitialPath(timeout: timing.initialPathTimeout)

        let configuration = settings.makeProbeConfiguration()
        let interface = pathMonitor.interface
        let hasPath = pathMonitor.isSatisfied
        let routerChangesBefore = pathMonitor.routerChangeCount

        // Work out which network this is before measuring, so the result is
        // filed in that network's own log.
        let network: NetworkProfile
        if hasPath {
            let gateway = pathMonitor.gatewayIP
            let isp = await identifier.ispInfo(gatewayIP: gateway, interface: interface)
            network = networks.resolve(NetworkObservation(interface: interface, gatewayIP: gateway, isp: isp))
        } else {
            network = networks.networkForOfflineProbe()
        }
        let store = networks.store(for: network.id)

        // Read before appending: once the new result is in the log, the streak
        // it ends is no longer the "current" outage.
        let ongoingOutageStart = store.currentOutageStart()
        let previousResultAt = store.lastResult?.timestamp

        var result = await engine.run(
            configuration: configuration,
            interface: interface,
            hasNetworkPath: hasPath
        )
        result.networkID = network.id

        // Never file a result under a network it was not measured on. A probe
        // can run for a minute; if the device joined another router in that
        // time, part or all of this measurement belongs to the new network,
        // and appending it here would put one network's data in another's
        // log. Throw it away and measure the new network cleanly instead.
        //
        // The same applies if the network was deleted mid-test: writing to its
        // store would resurrect a folder the user just removed.
        guard pathMonitor.routerChangeCount == routerChangesBefore, networks.profile(id: network.id) != nil else {
            discardedProbeCount += 1
            logger.notice("Network changed during a test; discarded it and testing the new network")
            if loopTask != nil {
                wantsImmediateRun = true
            }
            result.note = "Not recorded: this device changed networks during the test."
            return result
        }

        // Only call it a recovery if this network's outage was still being
        // recorded. After a long gap — the laptop spent the weekend on another
        // network, or asleep — nobody knows when it actually came back.
        let outageWasCurrent = previousResultAt.map {
            result.timestamp.timeIntervalSince($0) <= settings.intervalSeconds + Self.recoveryGapAllowance
        } ?? false

        var recoveredAfter: TimeInterval?
        if let ongoingOutageStart, outageWasCurrent, !result.isOutage {
            let downtime = max(0, result.timestamp.timeIntervalSince(ongoingOutageStart))
            recoveredAfter = downtime
            let recovery = "Back online after \(Format.duration(downtime)) (outage began \(ongoingOutageStart.formatted(date: .omitted, time: .shortened)))."
            result.note = [recovery, result.note].compactMap { $0 }.joined(separator: " ")
        }

        probesThisSession += 1
        // A probe just ran; the next reachability check can wait a full interval.
        nextRecoveryCheckAt = Date().addingTimeInterval(timing.recoveryCheckInterval)

        store.append(result, retentionDays: settings.retentionDays)
        notifications.handle(
            result: result,
            notifiesOnFailure: settings.notifiesOnFailure,
            recoveredAfter: recoveredAfter
        )

        if let recoveredAfter {
            logger.notice("Connection restored after \(Int(recoveredAfter), privacy: .public)s")
        }
        if let kind = result.errorKind {
            logger.warning("Probe failed: \(kind.rawValue, privacy: .public)")
        } else {
            logger.info("Probe ok on \(network.displayName, privacy: .private): \(result.downloadMbps ?? 0, format: .fixed(precision: 1), privacy: .public) Mbps down, \(result.uploadMbps ?? 0, format: .fixed(precision: 1), privacy: .public) up, \(result.latencyMs ?? 0, format: .fixed(precision: 0), privacy: .public) ms")
        }

        return result
    }

    /// Slack on top of the test interval when deciding whether an outage was
    /// still ongoing: covers settle delays, slow probes, and a short sleep.
    static let recoveryGapAllowance: TimeInterval = 10 * 60

    // MARK: App Nap

    /// Asks macOS not to throttle the app while it is monitoring.
    ///
    /// A menu bar app with no visible window is a prime App Nap candidate, and
    /// a napped app's timers can be delayed by minutes — which would quietly
    /// turn a 15-minute schedule into something much coarser. Idle *system*
    /// sleep is deliberately still allowed: keeping a Mac awake all day to run
    /// speed tests is not a trade the user asked for.
    private func beginBackgroundActivity() {
        #if os(macOS)
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Monitoring internet bandwidth on a schedule"
        )
        #endif
    }

    private func endBackgroundActivity() {
        #if os(macOS)
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
        }
        activityToken = nil
        #endif
    }
}
