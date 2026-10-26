//
//  ProbeResult.swift
//  RouterWatch
//

import Foundation

/// Which interface carried the probe. Recorded so a run of failures can be
/// pinned on the Wi-Fi leg rather than the router's WAN side.
enum InterfaceKind: String, Codable, Sendable, CaseIterable {
    case wifi
    case wired
    case cellular
    case other
    case none

    var title: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .wired: return "Ethernet"
        case .cellular: return "Cellular"
        case .other: return "Other"
        case .none: return "None"
        }
    }

    var symbolName: String {
        switch self {
        case .wifi: return "wifi"
        case .wired: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .other: return "network"
        case .none: return "wifi.slash"
        }
    }
}

/// One completed measurement against the external test point.
///
/// A result is recorded whether the probe succeeded or failed — the failures
/// are the whole point of running this all day, so they are first-class rows
/// in the log rather than something swallowed and retried.
struct ProbeResult: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var timestamp: Date
    var endpointName: String
    var interface: InterfaceKind

    var downloadMbps: Double?
    var uploadMbps: Double?
    var latencyMs: Double?
    var jitterMs: Double?

    var bytesDownloaded: Int
    var bytesUploaded: Int
    /// Wall-clock seconds the whole probe took, including latency samples.
    var duration: TimeInterval

    var errorKind: ErrorKind?
    var errorDetail: String?
    /// Something worth knowing that is not a failure — for example, that the
    /// primary test point was throttling and the fallback was used instead.
    /// Optional, so logs written before this field existed still decode.
    var note: String?
    /// The `NetworkProfile` this result was recorded on. Optional so results
    /// from before networks were tracked still decode.
    var networkID: String?

    var isFailure: Bool { errorKind != nil }
    var isOutage: Bool { errorKind?.isHardFailure == true }

    /// A short line suitable for the menu bar and log rows.
    var summaryLine: String {
        if let errorKind {
            return errorKind.title
        }
        if let downloadMbps {
            return String(format: "%.1f Mbps down", downloadMbps)
        }
        return "OK"
    }
}

extension ProbeResult {
    /// Convenience builder for a probe that never got off the ground.
    static func failure(
        timestamp: Date = Date(),
        endpointName: String,
        interface: InterfaceKind,
        kind: ErrorKind,
        detail: String,
        duration: TimeInterval = 0,
        note: String? = nil
    ) -> ProbeResult {
        ProbeResult(
            timestamp: timestamp,
            endpointName: endpointName,
            interface: interface,
            downloadMbps: nil,
            uploadMbps: nil,
            latencyMs: nil,
            jitterMs: nil,
            bytesDownloaded: 0,
            bytesUploaded: 0,
            duration: duration,
            errorKind: kind,
            errorDetail: detail,
            note: note
        )
    }
}
