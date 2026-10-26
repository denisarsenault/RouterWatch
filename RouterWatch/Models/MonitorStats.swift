//
//  MonitorStats.swift
//  RouterWatch
//

import Foundation

/// The windows the dashboard, chart, and log can be scoped to.
enum TimeRange: String, CaseIterable, Identifiable, Sendable {
    case hour24
    case days7
    case days30
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour24: return "24 Hours"
        case .days7: return "7 Days"
        case .days30: return "30 Days"
        case .all: return "All Time"
        }
    }

    var shortTitle: String {
        switch self {
        case .hour24: return "24h"
        case .days7: return "7d"
        case .days30: return "30d"
        case .all: return "All"
        }
    }

    /// The oldest timestamp inside this window, or `nil` for "everything".
    func startDate(now: Date = Date()) -> Date? {
        switch self {
        case .hour24: return now.addingTimeInterval(-86_400)
        case .days7: return now.addingTimeInterval(-7 * 86_400)
        case .days30: return now.addingTimeInterval(-30 * 86_400)
        case .all: return nil
        }
    }
}

/// One bar in the error breakdown chart.
struct ErrorTally: Identifiable, Hashable, Sendable {
    var kind: ErrorKind
    var count: Int
    var id: String { kind.rawValue }
}

/// Aggregates over a set of probes. Pure value math so it is straightforward
/// to unit test without touching the network or the disk.
struct MonitorStats: Sendable, Equatable {
    var sampleCount: Int = 0
    var failureCount: Int = 0
    var outageCount: Int = 0
    var averageDownloadMbps: Double?
    var medianDownloadMbps: Double?
    var minDownloadMbps: Double?
    var maxDownloadMbps: Double?
    var averageUploadMbps: Double?
    var averageLatencyMs: Double?
    var averageJitterMs: Double?
    var errorTallies: [ErrorTally] = []

    var successCount: Int { sampleCount - failureCount }

    /// Share of probes that completed without any error, degraded ones included
    /// in the denominator.
    var successRate: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(successCount) / Double(sampleCount)
    }

    /// Share of probes where data actually moved. This is the number to quote
    /// at an ISP: it excludes merely-slow results.
    var availability: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(sampleCount - outageCount) / Double(sampleCount)
    }

    var worstError: ErrorTally? {
        errorTallies.max { $0.count < $1.count }
    }

    static func compute(from results: [ProbeResult]) -> MonitorStats {
        var stats = MonitorStats()
        stats.sampleCount = results.count
        guard !results.isEmpty else { return stats }

        stats.failureCount = results.filter(\.isFailure).count
        stats.outageCount = results.filter(\.isOutage).count

        let downloads = results.compactMap(\.downloadMbps).sorted()
        if !downloads.isEmpty {
            stats.averageDownloadMbps = downloads.reduce(0, +) / Double(downloads.count)
            stats.minDownloadMbps = downloads.first
            stats.maxDownloadMbps = downloads.last
            stats.medianDownloadMbps = downloads.median()
        }

        let uploads = results.compactMap(\.uploadMbps)
        if !uploads.isEmpty {
            stats.averageUploadMbps = uploads.reduce(0, +) / Double(uploads.count)
        }

        let latencies = results.compactMap(\.latencyMs)
        if !latencies.isEmpty {
            stats.averageLatencyMs = latencies.reduce(0, +) / Double(latencies.count)
        }

        let jitters = results.compactMap(\.jitterMs)
        if !jitters.isEmpty {
            stats.averageJitterMs = jitters.reduce(0, +) / Double(jitters.count)
        }

        stats.errorTallies = tally(results)
        return stats
    }

    /// Counts per error type, heaviest first. Only kinds that actually occurred
    /// get a bar — an empty chart is a clearer "nothing went wrong" than eleven
    /// bars of zero.
    static func tally(_ results: [ProbeResult]) -> [ErrorTally] {
        var counts: [ErrorKind: Int] = [:]
        for result in results {
            guard let kind = result.errorKind else { continue }
            counts[kind, default: 0] += 1
        }
        return counts
            .map { ErrorTally(kind: $0.key, count: $0.value) }
            .sorted {
                $0.count == $1.count ? $0.kind.sortRank < $1.kind.sortRank : $0.count > $1.count
            }
    }
}

private extension Array where Element == Double {
    /// Assumes the receiver is already sorted ascending.
    func median() -> Double? {
        guard !isEmpty else { return nil }
        let middle = count / 2
        if count % 2 == 0 {
            return (self[middle - 1] + self[middle]) / 2
        }
        return self[middle]
    }
}
