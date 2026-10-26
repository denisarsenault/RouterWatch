//
//  Formatting.swift
//  RouterWatch
//

import Foundation
import SwiftUI

enum Format {

    static func mbps(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 100 { return String(format: "%.0f Mbps", value) }
        if value >= 10 { return String(format: "%.1f Mbps", value) }
        return String(format: "%.2f Mbps", value)
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f ms", value)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "now" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, remainder)
        }
        return "\(remainder)s"
    }

    /// "45s", "12m 5s", "3h 20m" — the two largest units, for outage lengths.
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(0, seconds.rounded())) ?? "0s"
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    static func shortTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

extension ConnectionHealth {
    var tint: Color {
        switch self {
        case .healthy: return .green
        case .degraded: return .orange
        case .down: return .red
        case .paused: return .secondary
        case .unknown: return .secondary
        }
    }
}

extension ErrorKind {
    /// Hard failures read red, degradations amber, housekeeping grey — so the
    /// breakdown chart communicates severity before any label is read.
    var tint: Color {
        switch self {
        case .lowThroughput, .highLatency: return .orange
        case .cancelled: return .gray
        case .httpError, .rateLimited: return .yellow
        default: return .red
        }
    }
}
