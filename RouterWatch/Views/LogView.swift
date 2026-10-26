//
//  LogView.swift
//  RouterWatch
//

import SwiftUI

#if os(macOS)
import AppKit
#endif

#if os(iOS)
import UIKit
#endif

/// The full probe log, newest first, filterable by outcome and error type.
struct LogView: View {

    @Environment(AppEnvironment.self) private var model

    @State private var range: TimeRange = .days7
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var isShowingClearConfirmation = false
    @State private var exportMessage: String?

    enum Filter: Hashable {
        case all
        case failuresOnly
        case kind(ErrorKind)

        var title: String {
            switch self {
            case .all: return "All Results"
            case .failuresOnly: return "Failures Only"
            case .kind(let kind): return kind.title
            }
        }
    }

    private var availableFilters: [Filter] {
        var filters: [Filter] = [.all, .failuresOnly]
        filters.append(contentsOf: model.store.errorTallies(in: range).map { .kind($0.kind) })
        return filters
    }

    private var entries: [ProbeResult] {
        var values = model.store.results(in: range)

        switch filter {
        case .all:
            break
        case .failuresOnly:
            values = values.filter(\.isFailure)
        case .kind(let kind):
            values = values.filter { $0.errorKind == kind }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            values = values.filter { result in
                result.summaryLine.lowercased().contains(query)
                    || (result.errorDetail ?? "").lowercased().contains(query)
                    || result.endpointName.lowercased().contains(query)
                    || result.interface.title.lowercased().contains(query)
            }
        }

        return values.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            list
        }
        .navigationTitle("Log")
        #if !os(tvOS)
        .searchable(text: $searchText, prompt: "Search the log")
        .toolbar { toolbarContent }
        .confirmationDialog(
            "Delete this network's log?",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Measurements", role: .destructive) {
                model.store.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all \(model.store.results.count) measurements recorded on \(viewedNetworkName). Other networks are not affected. Export first if you need the history.")
        }
        .alert(
            "Export",
            isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } }),
            actions: { Button("OK") { exportMessage = nil } },
            message: { Text(exportMessage ?? "") }
        )
        #endif
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                NetworkPicker()
                TimeRangePicker(range: $range)
                Spacer(minLength: 0)
                Text("\(entries.count) of \(model.store.results.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Picker("Filter", selection: $filter) {
                ForEach(availableFilters, id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }
            #if !os(tvOS)
            .pickerStyle(.menu)
            .frame(maxWidth: 260, alignment: .leading)
            #endif
        }
        .padding()
    }

    private var viewedNetworkName: String {
        model.networks.viewedProfile?.displayName ?? "this network"
    }

    // MARK: List

    private var list: some View {
        Group {
            if entries.isEmpty {
                EmptyStateView(
                    symbolName: "list.bullet.rectangle",
                    title: "Nothing to show",
                    message: model.store.results.isEmpty
                        ? "The log fills in as tests run."
                        : "No entries match the current filter."
                )
                .frame(maxHeight: .infinity)
            } else {
                List(entries) { result in
                    LogRow(result: result)
                }
                #if os(macOS)
                .listStyle(.inset)
                #endif
            }
        }
    }

    // MARK: Toolbar

    #if !os(tvOS)
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                export(asCSV: true)
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .disabled(entries.isEmpty)
        }
        ToolbarItem {
            Button(role: .destructive) {
                isShowingClearConfirmation = true
            } label: {
                Label("Clear Log", systemImage: "trash")
            }
            .disabled(model.store.results.isEmpty)
        }
    }

    /// Writes the current filtered view of the log to a file the user picks.
    private func export(asCSV: Bool) {
        // Exported oldest-first, which is what a spreadsheet wants.
        let rows = Array(entries.reversed())
        do {
            let data: Data
            let filename: String
            if asCSV {
                data = Data(ExportService.csv(from: rows, networkName: viewedNetworkName).utf8)
                filename = ExportService.suggestedFilename(networkName: viewedNetworkName, extension: "csv")
            } else {
                data = try ExportService.json(from: rows)
                filename = ExportService.suggestedFilename(networkName: viewedNetworkName, extension: "json")
            }
            #if os(macOS)
            saveWithPanel(data: data, suggestedName: filename)
            #else
            let url = try ExportService.writeTemporaryFile(named: filename, contents: data)
            presentShareSheet(for: url)
            #endif
        } catch {
            exportMessage = error.localizedDescription
        }
    }
    #endif

    #if os(macOS)
    private func saveWithPanel(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            exportMessage = error.localizedDescription
        }
    }
    #endif

    #if os(iOS)
    private func presentShareSheet(for url: URL) {
        let scenes = UIApplication.shared.connectedScenes
        guard
            let scene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let root = scene.keyWindow?.rootViewController
        else {
            exportMessage = "Could not open the share sheet."
            return
        }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad requires an anchor or the popover cannot be presented.
        controller.popoverPresentationController?.sourceView = root.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: root.view.bounds.midX,
            y: root.view.bounds.midY,
            width: 0,
            height: 0
        )
        root.present(controller, animated: true)
    }
    #endif
}

/// One row of the log. Shows the numbers when a probe worked and the failure
/// reason when it did not.
struct LogRow: View {
    let result: ProbeResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: result.errorKind?.symbolName ?? "checkmark.circle")
                .foregroundStyle(result.errorKind?.tint ?? .green)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(Format.timestamp(result.timestamp))
                        .font(.callout)
                        .monospacedDigit()
                    Label(result.interface.title, systemImage: result.interface.symbolName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let kind = result.errorKind {
                    Text(kind.title)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(kind.tint)
                    if let detail = result.errorDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let note = result.note {
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 14) {
                    measurement("↓", Format.mbps(result.downloadMbps))
                    measurement("↑", Format.mbps(result.uploadMbps))
                    measurement("RTT", Format.milliseconds(result.latencyMs))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func measurement(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
            Text(value)
        }
    }
}
