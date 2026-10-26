//
//  Components.swift
//  RouterWatch
//

import SwiftUI

/// A single headline number with a caption.
struct StatTile: View {
    let title: String
    let value: String
    var caption: String?
    var symbolName: String?
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Coloured pill naming an error type. Used in the log and the chart legend.
struct ErrorBadge: View {
    let kind: ErrorKind

    var body: some View {
        Label(kind.title, systemImage: kind.symbolName)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(kind.tint.opacity(0.18), in: Capsule())
            .foregroundStyle(kind.tint)
    }
}

/// Section heading with an optional trailing control.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Shown wherever a chart or list would otherwise be blank.
struct EmptyStateView: View {
    let symbolName: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// The 24h / 7d / 30d / All selector.
///
/// tvOS gets a row of focusable buttons instead of a segmented picker, which
/// SwiftUI does not offer there and which would not be navigable by remote
/// anyway.
struct TimeRangePicker: View {
    @Binding var range: TimeRange

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 12) {
            ForEach(TimeRange.allCases) { value in
                Button(value.shortTitle) { range = value }
                    .buttonStyle(.bordered)
                    .background(
                        value == range ? Color.accentColor.opacity(0.35) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
        }
        #else
        Picker("Range", selection: $range) {
            ForEach(TimeRange.allCases) { value in
                Text(value.shortTitle).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)
        #endif
    }
}

/// Lays stat tiles out in as many columns as fit, so four of them wrap to two
/// rows on a phone instead of squeezing each label into a vertical letter
/// stack.
struct StatTileGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinimumWidth), spacing: 12)], spacing: 12) {
            content
        }
    }

    private var tileMinimumWidth: CGFloat {
        #if os(tvOS)
        return 320
        #else
        return 150
        #endif
    }
}

/// Chooses which network's results the dashboard, chart, and log show.
struct NetworkPicker: View {
    @Environment(AppEnvironment.self) private var model

    var body: some View {
        let networks = model.networks
        Menu {
            if let active = networks.activeProfile {
                Button {
                    networks.view(nil)
                } label: {
                    Label("Current: \(active.displayName)", systemImage: networks.isViewingActiveNetwork ? "checkmark" : "location")
                }
                Divider()
            }
            ForEach(networks.sortedProfiles.filter { $0.id != networks.activeNetworkID }) { profile in
                Button {
                    networks.view(profile.id)
                } label: {
                    if networks.viewedNetworkID == profile.id {
                        Label(profile.displayName, systemImage: "checkmark")
                    } else {
                        Text(profile.displayName)
                    }
                }
            }
        } label: {
            Label(networks.viewedProfile?.displayName ?? "No network yet", systemImage: "network")
                .lineLimit(1)
        }
        .disabled(networks.profiles.isEmpty)
        #if os(macOS)
        .fixedSize()
        #endif
    }
}

/// Shown when the results on screen are not from the network the device is on,
/// so old numbers are never mistaken for the current connection.
struct OtherNetworkBanner: View {
    @Environment(AppEnvironment.self) private var model

    var body: some View {
        let networks = model.networks
        if !networks.isViewingActiveNetwork, let viewed = networks.viewedProfile {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
                Text(bannerText(viewed: viewed))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if networks.activeProfile != nil {
                    Button("Show Current") { networks.view(nil) }
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func bannerText(viewed: NetworkProfile) -> String {
        if let active = model.networks.activeProfile {
            return "Showing results for \(viewed.displayName). This device is on \(active.displayName)."
        }
        return "Showing results for \(viewed.displayName)."
    }
}
