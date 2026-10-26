//
//  RouterWatchShortcuts.swift
//  RouterWatch
//

import AppIntents

/// The phrases Siri and Spotlight recognise without the user building a
/// shortcut first.
///
/// Every phrase has to contain the app name, which is what tells the system
/// which app is being asked. Several wordings are offered for the same action
/// because people ask for a speed test in more ways than one.
struct RouterWatchShortcuts: AppShortcutsProvider {

    /// Shown in Settings so the phrases are discoverable without opening
    /// Shortcuts. Mirrors `appShortcuts` below, with the app's name spelled
    /// out in place of the `applicationName` token.
    static let spokenExamples = [
        "Run a speed test with RouterWatch",
        "Is my internet working in RouterWatch",
        "Get my network statistics from RouterWatch",
        "Pause RouterWatch monitoring"
    ]

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunSpeedTestIntent(),
            phrases: [
                "Run a speed test with \(.applicationName)",
                "Test my internet with \(.applicationName)",
                "Check my speed with \(.applicationName)",
                "\(.applicationName) speed test"
            ],
            shortTitle: "Run Speed Test",
            systemImageName: "speedometer"
        )

        AppShortcut(
            intent: GetConnectionStatusIntent(),
            phrases: [
                "Is my internet working in \(.applicationName)",
                "Check my connection with \(.applicationName)",
                "\(.applicationName) status"
            ],
            shortTitle: "Connection Status",
            systemImageName: "wifi"
        )

        AppShortcut(
            intent: GetNetworkStatisticsIntent(),
            phrases: [
                "Get my network statistics from \(.applicationName)",
                "How reliable is my internet in \(.applicationName)",
                "\(.applicationName) statistics"
            ],
            shortTitle: "Network Statistics",
            systemImageName: "chart.bar"
        )

        AppShortcut(
            intent: SetMonitoringIntent(),
            phrases: [
                "Set monitoring in \(.applicationName)",
                "Pause \(.applicationName) monitoring"
            ],
            shortTitle: "Set Monitoring",
            systemImageName: "pause.circle"
        )
    }
}
