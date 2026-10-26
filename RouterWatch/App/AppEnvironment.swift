//
//  AppEnvironment.swift
//  RouterWatch
//

import Foundation
import Observation

#if os(macOS)
import AppKit
#endif

/// The object graph, assembled once and handed down through the SwiftUI
/// environment so every platform's scene wires up identically.
@MainActor
@Observable
final class AppEnvironment {

    /// Created once at launch. The iOS background scheduler needs the graph to
    /// exist before `application(_:didFinishLaunchingWithOptions:)` returns,
    /// which is earlier than any view can provide it.
    static let shared = AppEnvironment()

    let settings: SettingsStore
    let networks: NetworkLibrary
    let pathMonitor: NetworkPathMonitor
    let notifications: NotificationService
    let monitor: MonitorController

    #if os(macOS)
    let loginItems: LoginItemManager
    static let mainWindowID = "routerwatch.main"
    #endif

    #if os(iOS)
    let background: BackgroundRefreshCoordinator
    #endif

    /// The measurement log for the network the UI is showing.
    var store: MeasurementStore { networks.viewedStore }

    @ObservationIgnored private var hasBootstrapped = false
    @ObservationIgnored private var hasPreparedData = false

    /// Parameters exist for tests, which build an environment on a temporary
    /// directory with a scripted engine rather than the real one.
    init(
        rootDirectory: URL = NetworkLibrary.defaultRootDirectory(),
        defaults: UserDefaults = .standard,
        engine: ProbeRunning = SpeedTestEngine(),
        identifier: NetworkIdentifying = NetworkIdentifier(),
        timing: MonitorTiming = .standard
    ) {
        let settings = SettingsStore(defaults: defaults)
        let networks = NetworkLibrary(rootDirectory: rootDirectory)
        let pathMonitor = NetworkPathMonitor()
        let notifications = NotificationService()

        self.settings = settings
        self.networks = networks
        self.pathMonitor = pathMonitor
        self.notifications = notifications
        self.monitor = MonitorController(
            settings: settings,
            networks: networks,
            pathMonitor: pathMonitor,
            notifications: notifications,
            engine: engine,
            identifier: identifier,
            timing: timing
        )

        #if os(macOS)
        self.loginItems = LoginItemManager()
        #endif

        #if os(iOS)
        self.background = BackgroundRefreshCoordinator()
        #endif
    }

    /// Loads the logs and starts watching the network path.
    ///
    /// Separate from `bootstrap()` because App Intents run in a launch of their
    /// own: an intent needs the data, but must not provoke a notification
    /// permission prompt or rearrange the Dock on the user's behalf.
    func prepareData() {
        guard !hasPreparedData else { return }
        hasPreparedData = true

        pathMonitor.start()
        networks.load()
        networks.mergeRouterlessDuplicates()
        networks.pruneAll(retentionDays: settings.retentionDays)

        // Clears readings that older builds recorded when a test server
        // refused with a token-sized response. Runs at every launch rather
        // than behind a "done" flag: it only ever removes rows the current
        // code cannot produce, it costs one pass over the log, and a
        // preferences flag is not dependable for a bundle ID that runs both
        // sandboxed and unsandboxed.
        networks.removeRefusalArtifacts()
    }

    /// Everything that has to happen once, after launch.
    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        prepareData()

        #if os(macOS)
        loginItems.refresh()
        applyDockIconPolicy()
        #endif

        // Before asking about notifications: that prompt blocks until the user
        // answers it, and monitoring must not wait on a dialog.
        if settings.isMonitoringEnabled {
            monitor.start()
        }

        await notifications.requestAuthorizationIfNeeded()

        #if os(iOS)
        background.schedule(intervalSeconds: settings.intervalSeconds)
        #endif
    }

    #if os(macOS)
    /// Switches between a regular Dock app and a menu-bar-only accessory.
    ///
    /// Done at runtime rather than with a static `LSUIElement` so the same
    /// build supports both and the preference can be changed without a
    /// reinstall. Coming back from `.accessory` needs an explicit activate, or
    /// the app would be frontmost-by-policy but still behind other windows.
    func applyDockIconPolicy() {
        let policy: NSApplication.ActivationPolicy = settings.hidesDockIcon ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    #endif
}
