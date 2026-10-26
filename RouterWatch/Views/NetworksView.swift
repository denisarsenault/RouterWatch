//
//  NetworksView.swift
//  RouterWatch
//

import SwiftUI

/// Every network RouterWatch has measured, with what identifies it and
/// controls to rename it, look at its results, or delete its history.
struct NetworksView: View {

    @Environment(AppEnvironment.self) private var model
    /// Switches the app to the dashboard after choosing a network to view.
    var onShowResults: () -> Void = {}

    @State private var renaming: NetworkProfile?
    @State private var draftName = ""
    @State private var deleting: NetworkProfile?

    var body: some View {
        let profiles = model.networks.sortedProfiles

        Group {
            if profiles.isEmpty {
                EmptyStateView(
                    symbolName: "network",
                    title: "No networks yet",
                    message: "RouterWatch identifies each network the first time it tests one. Results from every network are kept separately."
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(profiles) { profile in
                            NetworkRow(
                                profile: profile,
                                isActive: profile.id == model.networks.activeNetworkID,
                                store: model.networks.store(for: profile.id),
                                onView: {
                                    model.networks.view(profile.id)
                                    onShowResults()
                                },
                                onRename: {
                                    draftName = profile.customName ?? ""
                                    renaming = profile
                                },
                                onDelete: { deleting = profile }
                            )
                        }
                    } footer: {
                        Text("Networks are told apart by internet provider and router address — details RouterWatch can read without asking for extra permissions. Give each one a name you'll recognise.")
                    }
                }
            }
        }
        .navigationTitle("Networks")
        .alert(
            "Rename Network",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { profile in
            TextField(profile.automaticName, text: $draftName)
            Button("Save") {
                model.networks.rename(profile.id, to: draftName)
                renaming = nil
            }
            if profile.customName != nil {
                Button("Use Automatic Name") {
                    model.networks.rename(profile.id, to: nil)
                    renaming = nil
                }
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { profile in
            Text("Leave blank to use “\(profile.automaticName)”.")
        }
        .confirmationDialog(
            "Delete this network?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { profile in
            Button("Delete \(profile.displayName)", role: .destructive) {
                model.networks.delete(profile.id)
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { profile in
            Text("Permanently removes all \(model.networks.store(for: profile.id).results.count) measurements recorded on this network. Other networks are not affected.")
        }
    }
}

private struct NetworkRow: View {
    let profile: NetworkProfile
    let isActive: Bool
    let store: MeasurementStore
    let onView: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    private var weekStats: MonitorStats { store.stats(in: .days7) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: profile.isCellular ? "antenna.radiowaves.left.and.right" : "network")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.headline)
                    if profile.customName != nil {
                        Text(profile.automaticName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if isActive {
                    Text("Current")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let isp = profile.isp {
                    detail("Provider", "\(isp.organization) (AS\(isp.asn))")
                    if let ip = isp.publicIP { detail("Public IP", ip) }
                    if let location = isp.locationDescription { detail("Location", location) }
                } else if !profile.isLegacy {
                    detail("Provider", "Not identified yet — the internet was unreachable")
                }
                if let gateway = profile.gatewayIP { detail("Router", gateway) }
                if !profile.interfacesSeen.isEmpty {
                    detail("Connected via", profile.interfacesSeen.map(\.title).joined(separator: ", "))
                }
                detail("Seen", "\(profile.firstSeen.formatted(date: .abbreviated, time: .omitted)) – \(Format.relative(profile.lastSeen))")
                detail(
                    "Measurements",
                    weekStats.sampleCount > 0
                        ? "\(store.results.count) total · \(Format.percent(weekStats.availability)) available this week"
                        : "\(store.results.count) total"
                )
            }

            HStack(spacing: 12) {
                Button("View Results", action: onView)
                    .disabled(store.results.isEmpty)
                Button("Rename…", action: onRename)
                Button("Delete…", role: .destructive, action: onDelete)
            }
            #if !os(tvOS)
            .buttonStyle(.borderless)
            #endif
            .font(.callout)
        }
        .padding(.vertical, 6)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }

    private var labelWidth: CGFloat {
        #if os(tvOS)
        return 220
        #else
        return 100
        #endif
    }
}
