//
//  RootView.swift
//  RouterWatch
//

import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case errors
    case log
    case networks
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .errors: return "Errors"
        case .log: return "Log"
        case .networks: return "Networks"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: return "speedometer"
        case .errors: return "chart.bar.xaxis"
        case .log: return "list.bullet.rectangle"
        case .networks: return "network"
        case .settings: return "gearshape"
        }
    }
}

/// Picks the navigation container that suits each platform: a sidebar on the
/// Mac, tabs on iPhone, iPad, and Apple TV.
struct RootView: View {

    @Environment(AppEnvironment.self) private var model
    @State private var selection: AppSection = .dashboard

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            NavigationStack {
                destination(for: selection)
            }
        }
        #else
        TabView(selection: $selection) {
            ForEach(AppSection.allCases) { section in
                NavigationStack {
                    destination(for: section)
                }
                .tabItem {
                    Label(section.title, systemImage: section.symbolName)
                }
                .tag(section)
            }
        }
        #endif
    }

    @ViewBuilder
    private func destination(for section: AppSection) -> some View {
        switch section {
        case .dashboard: DashboardView()
        case .errors: ErrorBreakdownView()
        case .log: LogView()
        case .networks: NetworksView(onShowResults: { selection = .dashboard })
        case .settings: SettingsView()
        }
    }
}
