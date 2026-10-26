//
//  SettingsView.swift
//  RouterWatch
//

import AppIntents
import SwiftUI

/// `Form` is not a good fit on tvOS, so the same sections are wrapped in a
/// plain `List` there.
struct SettingsContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(tvOS)
        List { content }
        #else
        Form { content }
            .formStyle(.grouped)
        #endif
    }
}

struct SettingsView: View {

    @Environment(AppEnvironment.self) private var model
    #if os(macOS)
    @Environment(\.openURL) private var openURL
    #endif

    var body: some View {
        SettingsContainer {
            scheduleSection(store: model.settings)
            endpointSection(store: model.settings)
            payloadSection(store: model.settings)
            thresholdSection(store: model.settings)
            historySection(store: model.settings)
            #if os(macOS)
            macSection(store: model.settings)
            #endif
            shortcutsSection
            aboutSection
        }
        .navigationTitle("Settings")
    }

    // MARK: Schedule

    private func scheduleSection(store: SettingsStore) -> some View {
        @Bindable var settings = store
        return Section {
            Toggle("Monitor continuously", isOn: Binding(
                get: { settings.isMonitoringEnabled },
                set: { model.monitor.setMonitoring(enabled: $0) }
            ))

            Picker("Test every", selection: $settings.intervalMinutes) {
                ForEach(SettingsStore.intervalChoices, id: \.self) { minutes in
                    Text(minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes == 60 ? "" : "s")")
                        .tag(minutes)
                }
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text(scheduleFooter)
        }
    }

    private var scheduleFooter: String {
        #if os(macOS)
        return "RouterWatch keeps testing while it runs in the menu bar, including when its window is closed. Frequent large tests consume real bandwidth — at 25 MB every 15 minutes that is roughly 2.4 GB per day — and public test servers throttle networks that test too often. If the test point starts rate limiting, RouterWatch backs off and uses the other test point until it recovers."
        #elseif os(iOS)
        return "iOS only allows background work opportunistically, so scheduled tests run reliably while RouterWatch is open and best-effort when it is not. For genuine all-day coverage, run the Mac version."
        #else
        return "tvOS runs tests while RouterWatch is open. For all-day coverage, run the Mac version."
        #endif
    }

    // MARK: Endpoint

    private func endpointSection(store: SettingsStore) -> some View {
        @Bindable var settings = store
        return Section {
            Picker("Test point", selection: $settings.endpointID) {
                ForEach(TestEndpoint.presets) { endpoint in
                    Text(endpoint.name).tag(endpoint.id)
                }
                Text("Custom URL").tag(TestEndpoint.customIdentifier)
            }

            if settings.endpointID == TestEndpoint.customIdentifier {
                TextField("https://example.com/testfile", text: $settings.customDownloadURLString)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
        } header: {
            Text("Test Point")
        } footer: {
            Text(settings.activeEndpoint.notes + " Every option is outside your local network, so a failure points at the router's WAN side or beyond — not at your Wi-Fi. HTTPS only.")
        }
    }

    // MARK: Payload

    private func payloadSection(store: SettingsStore) -> some View {
        @Bindable var settings = store
        return Section {
            if settings.activeEndpoint.supportsAdjustableDownloadSize {
                Picker("Download size", selection: $settings.downloadMegabytes) {
                    ForEach(SettingsStore.downloadSizeChoices, id: \.self) { size in
                        Text("\(size) MB").tag(size)
                    }
                }
            }

            Toggle("Measure upload", isOn: $settings.measuresUpload)
                .disabled(!settings.activeEndpoint.supportsUpload)

            if settings.measuresUpload && settings.activeEndpoint.supportsUpload {
                Picker("Upload size", selection: $settings.uploadMegabytes) {
                    ForEach(SettingsStore.uploadSizeChoices, id: \.self) { size in
                        Text("\(size) MB").tag(size)
                    }
                }
            }

            Toggle("Measure latency and jitter", isOn: $settings.measuresLatency)
        } header: {
            Text("Measurements")
        } footer: {
            Text("A larger download measures a fast line more accurately but uses more data. The first 0.3 seconds of each transfer is discarded so TCP slow start does not drag the result down.")
        }
    }

    // MARK: Thresholds

    private func thresholdSection(store: SettingsStore) -> some View {
        @Bindable var settings = store
        return Section {
            Picker("Flag downloads below", selection: $settings.lowThroughputThresholdMbps) {
                ForEach(SettingsStore.throughputThresholdChoices, id: \.self) { value in
                    Text(value == 0 ? "Never" : "\(Int(value)) Mbps").tag(value)
                }
            }

            Picker("Flag latency above", selection: $settings.highLatencyThresholdMs) {
                ForEach(SettingsStore.latencyThresholdChoices, id: \.self) { value in
                    Text("\(Int(value)) ms").tag(value)
                }
            }

            if model.notifications.isSupported {
                Toggle("Notify me when a test fails", isOn: $settings.notifiesOnFailure)
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text("Threshold breaches are logged as Low Throughput and High Latency — a line that is up but underperforming. Notifications are sent once per problem, not once per test, so an outage does not flood Notification Center.")
        }
    }

    // MARK: History

    private func historySection(store: SettingsStore) -> some View {
        @Bindable var settings = store
        return Section {
            Picker("Keep history for", selection: $settings.retentionDays) {
                ForEach(SettingsStore.retentionChoices, id: \.self) { days in
                    Text(days < 365 ? "\(days) days" : "1 year").tag(days)
                }
            }
            LabeledContent("Networks", value: "\(model.networks.profiles.count)")
            LabeledContent("Stored measurements", value: "\(model.networks.totalMeasurementCount)")
            if model.networks.removedArtifactCount > 0 {
                Label(
                    "Removed \(model.networks.removedArtifactCount) false readings recorded while a test server was throttling this network.",
                    systemImage: "sparkles"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let error = model.store.lastSaveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        } header: {
            Text("History")
        }
    }

    // MARK: macOS

    #if os(macOS)
    private func macSection(store: SettingsStore) -> some View {
        @Bindable var settings = store
        return Section {
            Toggle("Open at login", isOn: Binding(
                get: { model.loginItems.isEnabled },
                set: { newValue in
                    settings.launchesAtLogin = newValue
                    model.loginItems.setEnabled(newValue)
                }
            ))

            if model.loginItems.requiresApproval {
                Button("Open Login Items Settings…") {
                    model.loginItems.openLoginItemsSettings()
                }
            }

            Toggle("Show speed in the menu bar", isOn: $settings.showsSpeedInMenuBar)

            Toggle("Hide Dock icon (menu bar only)", isOn: Binding(
                get: { settings.hidesDockIcon },
                set: { newValue in
                    settings.hidesDockIcon = newValue
                    model.applyDockIconPolicy()
                }
            ))
        } header: {
            Text("Mac")
        } footer: {
            Text(model.loginItems.statusDescription + " Closing the dashboard window leaves RouterWatch monitoring from the menu bar; use Quit to stop it entirely.")
        }
    }
    #endif

    // MARK: Siri and Shortcuts

    private var shortcutsSection: some View {
        Section {
            // `ShortcutsLink` is iOS-only; the Mac gets a plain button, and
            // tvOS has no Shortcuts app to send anyone to.
            #if os(iOS)
            ShortcutsLink()
            #elseif os(macOS)
            Button("Open Shortcuts…") {
                openURL(URL(string: "shortcuts://")!)
            }
            #endif
            ForEach(RouterWatchShortcuts.spokenExamples, id: \.self) { phrase in
                Label("“\(phrase)”", systemImage: "quote.bubble")
                    .font(.callout)
            }
        } header: {
            Text("Siri & Shortcuts")
        } footer: {
            Text("RouterWatch can run a test, report the connection, summarise a network, and pause monitoring from Shortcuts — useful in an automation that tests the line whenever you join a particular network.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.versionDescription)
            LabeledContent("Current network", value: model.networks.activeProfile?.displayName ?? "Not identified yet")
            LabeledContent("Current interface", value: model.pathMonitor.interface.title)
            LabeledContent("Tests this session", value: "\(model.monitor.probesThisSession)")
        } header: {
            Text("About")
        }
    }
}

extension Bundle {
    var versionDescription: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
