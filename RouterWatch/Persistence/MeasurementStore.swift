//
//  MeasurementStore.swift
//  RouterWatch
//

import Foundation
import Observation
import OSLog

/// One network's probe log: every measurement taken on it, held in memory and
/// mirrored to that network's JSON file. `NetworkLibrary` owns one per network.
///
/// A plain file rather than SwiftData or Core Data, deliberately. The data is a
/// single append-only array of small value types with no relationships and no
/// migrations worth the name; at the default 15-minute interval a full year of
/// history is roughly 35,000 rows, which loads and filters in memory without
/// any of the overhead a store would add.
@MainActor
@Observable
final class MeasurementStore {

    /// Chronological, oldest first.
    private(set) var results: [ProbeResult] = []
    private(set) var isLoaded = false
    private(set) var lastSaveError: String?

    var lastResult: ProbeResult? { results.last }

    // MARK: Queries

    func results(in range: TimeRange, now: Date = Date()) -> [ProbeResult] {
        guard let start = range.startDate(now: now) else { return results }
        return results.filter { $0.timestamp >= start }
    }

    func stats(in range: TimeRange, now: Date = Date()) -> MonitorStats {
        MonitorStats.compute(from: results(in: range, now: now))
    }

    func errorTallies(in range: TimeRange, now: Date = Date()) -> [ErrorTally] {
        MonitorStats.tally(results(in: range, now: now))
    }

    /// When the ongoing outage began: the timestamp of the first result in the
    /// unbroken run of outages at the end of the log. `nil` when the most
    /// recent result is not an outage.
    func currentOutageStart() -> Date? {
        var start: Date?
        for result in results.reversed() {
            guard result.isOutage else { break }
            start = result.timestamp
        }
        return start
    }

    // MARK: Mutations

    func append(_ result: ProbeResult, retentionDays: Int) {
        results.append(result)
        prune(retentionDays: retentionDays)
        save()
    }

    /// Adds results that came from elsewhere — currently the one-time migration
    /// of the pre-network log — keeping the log in chronological order.
    func merge(_ incoming: [ProbeResult]) {
        guard !incoming.isEmpty else { return }
        results.append(contentsOf: incoming)
        results.sort { $0.timestamp < $1.timestamp }
    }

    /// Removes readings that were never measurements: a "successful" download
    /// that moved almost no data.
    ///
    /// Throttling endpoints answer `200 OK` with a few dozen bytes, which older
    /// builds divided by the elapsed time and logged as ~0 Mbps — usually as
    /// Low Throughput, blaming the connection for the server's refusal. Probes
    /// now reject these outright; this clears out the ones already recorded.
    ///
    /// The smallest download the app will ever request is 5 MB, so no honest
    /// result is anywhere near this floor. Genuinely slow tests, which moved
    /// the whole payload, are untouched.
    @discardableResult
    func removeRefusalArtifacts() -> Int {
        let before = results.count
        results.removeAll { result in
            result.downloadMbps != nil && result.bytesDownloaded < SpeedTestEngine.minimumMeasurableBytes
        }
        return before - results.count
    }

    /// Drops anything older than the retention window.
    ///
    /// Returns the number of rows removed so callers can tell whether a save is
    /// warranted on its own.
    @discardableResult
    func prune(retentionDays: Int, now: Date = Date()) -> Int {
        guard retentionDays > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let before = results.count
        results.removeAll { $0.timestamp < cutoff }
        return before - results.count
    }

    func clear() {
        results.removeAll()
        save()
    }

    // MARK: Persistence

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let ioQueue = DispatchQueue(
        label: "com.mybrightzone.routerwatch.measurement-store",
        qos: .utility
    )
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.mybrightzone.routerwatch",
        category: "MeasurementStore"
    )

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() {
        defer { isLoaded = true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([ProbeResult].self, from: data)
            results = decoded.sorted { $0.timestamp < $1.timestamp }
        } catch {
            // A corrupt log should not stop the app from monitoring. The old
            // file is kept aside rather than overwritten, in case the user
            // wants to salvage it.
            logger.error("Could not read measurement log: \(error.localizedDescription, privacy: .public)")
            let salvage = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: salvage)
            try? FileManager.default.moveItem(at: fileURL, to: salvage)
            results = []
        }
    }

    func save() {
        let snapshot = results
        let url = fileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        ioQueue.async { [weak self] in
            do {
                let data = try encoder.encode(snapshot)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
                Task { @MainActor in self?.lastSaveError = nil }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    self?.logger.error("Could not write measurement log: \(message, privacy: .public)")
                    self?.lastSaveError = message
                }
            }
        }
    }

    /// Blocks until queued writes have reached disk.
    func flushPendingWrites() {
        ioQueue.sync {}
    }
}
