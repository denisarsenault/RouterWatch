//
//  RouterWatchApp.swift
//  RouterWatch
//

import SwiftUI

@main
struct RouterWatchApp: App {

    /// A shared instance rather than `@State`, because the iOS background task
    /// identifier must be registered from `init()` — before launch finishes —
    /// and `@State` is not safe to read outside a view's lifetime.
    private let environmentModel = AppEnvironment.shared

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(iOS)
        let model = environmentModel
        model.background.register { [weak model] in
            await model?.monitor.probeOnce()
        }
        #endif
    }

    var body: some Scene {
        #if os(macOS)

        // No `.task { bootstrap() }` on the Mac scenes: monitoring starts from
        // the app delegate so it runs even when no view is ever rendered.
        Window("RouterWatch", id: AppEnvironment.mainWindowID) {
            RootView()
                .environment(environmentModel)
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Test Now") {
                    environmentModel.monitor.runNow()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarContentView()
                .environment(environmentModel)
        } label: {
            MenuBarLabel(
                symbolName: environmentModel.monitor.health.symbolName,
                title: environmentModel.monitor.menuBarTitle(
                    showsSpeed: environmentModel.settings.showsSpeedInMenuBar
                )
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(environmentModel)
                .frame(width: 520, height: 560)
        }

        #else

        WindowGroup {
            RootView()
                .environment(environmentModel)
                .task { await environmentModel.bootstrap() }
        }

        #endif
    }
}

#if os(macOS)

/// Small status-item label. Falls back to the icon alone when there is no
/// number worth showing, so the menu bar never displays a stale reading.
struct MenuBarLabel: View {
    let symbolName: String
    let title: String?

    var body: some View {
        if let title {
            Label(title, systemImage: symbolName)
        } else {
            Image(systemName: symbolName)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Starts monitoring at launch, independent of any window.
    ///
    /// Kicking this off from a view's `.task` is not enough on the Mac. When
    /// RouterWatch launches as a login item after the user last closed the
    /// dashboard, state restoration keeps the window closed, and the menu bar
    /// panel's content is not built until it is clicked — so no view would
    /// appear and monitoring would silently never start.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests host inside the app. Monitoring there would run real
        // speed tests and write into the user's real logs.
        guard !Self.isRunningUnitTests else { return }
        Task { @MainActor in
            await AppEnvironment.shared.bootstrap()
        }
    }

    /// Keeps a second copy of RouterWatch from running alongside the first.
    ///
    /// Each copy holds a network's log in memory and saves the whole thing, so
    /// two copies writing the same file take turns overwriting each other's new
    /// results. macOS normally prevents a second launch of the same app, but
    /// not of a second copy of it — a login item from Applications plus a build
    /// run from Xcode, for instance. The newcomer hands over to the copy that
    /// was already running, before it has loaded or written anything.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningUnitTests, let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        guard let existing = others.first else { return }
        existing.activate()
        exit(0)
    }

    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Closing the dashboard should leave the menu bar item monitoring, not
    /// quit the app — the whole point is that it runs all day.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

#endif
