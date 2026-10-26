//
//  SpeedTestEngine.swift
//  RouterWatch
//

import Foundation

/// Everything one probe needs to know, captured as a value so the engine never
/// reaches back into the UI or the settings store mid-run.
struct ProbeConfiguration: Sendable {
    var endpoint: TestEndpoint
    /// Used when `endpoint` answers but refuses — rate limiting, an HTTP error,
    /// an empty body. Never used for network-level failures, which are real
    /// outages and must be recorded as such.
    var fallbackEndpoint: TestEndpoint?
    var downloadBytes: Int
    var uploadBytes: Int
    var measuresUpload: Bool
    var measuresLatency: Bool
    var latencySampleCount: Int
    var requestTimeout: TimeInterval
    var lowThroughputThresholdMbps: Double
    var highLatencyThresholdMs: Double
}

/// Runs the download, upload, and latency measurements against the external
/// test point and reduces the outcome to a single `ProbeResult`.
///
/// An actor because the monitor loop and a manual "Test Now" can both ask for a
/// run; serialising them keeps two concurrent transfers from measuring each
/// other's congestion. It also owns the per-endpoint back-off state.
actor SpeedTestEngine {

    /// Endpoints that have told us to go away, and until when.
    ///
    /// Public speed-test servers throttle per network, and retrying a throttled
    /// server on every tick extends the penalty. While an endpoint is backing
    /// off, probes go straight to the fallback instead.
    private var backOffUntil: [String: Date] = [:]

    /// Used when a 429 arrives without a usable `Retry-After`.
    static let defaultBackOff: TimeInterval = 30 * 60
    /// Caps a hostile or malformed `Retry-After` so one response cannot
    /// sideline the primary endpoint for days.
    static let maximumBackOff: TimeInterval = 2 * 60 * 60

    func backOffDeadline(for endpointID: String, now: Date = Date()) -> Date? {
        guard let until = backOffUntil[endpointID], until > now else { return nil }
        return until
    }

    func run(
        configuration: ProbeConfiguration,
        interface: InterfaceKind,
        hasNetworkPath: Bool
    ) async -> ProbeResult {
        let startedAt = Date()
        let clockStart = CFAbsoluteTimeGetCurrent()
        func elapsed() -> TimeInterval { CFAbsoluteTimeGetCurrent() - clockStart }

        // No interface at all: record the outage immediately rather than
        // waiting out a timeout we already know the answer to.
        guard hasNetworkPath else {
            return .failure(
                timestamp: startedAt,
                endpointName: configuration.endpoint.name,
                interface: .none,
                kind: .noNetworkPath,
                detail: ProbeError.noNetworkPath.detail,
                duration: elapsed()
            )
        }

        var endpoint = configuration.endpoint
        var notes: [String] = []

        if let until = backOffDeadline(for: endpoint.id), let fallback = configuration.fallbackEndpoint {
            notes.append("\(endpoint.name) is rate limiting this network until \(until.formatted(date: .omitted, time: .shortened)); used \(fallback.name).")
            endpoint = fallback
        }

        var latencyMs: Double?
        var jitterMs: Double?
        var downloadMbps: Double?
        var uploadMbps: Double?
        var bytesDown = 0
        var bytesUp = 0

        func note() -> String? {
            notes.isEmpty ? nil : notes.joined(separator: " ")
        }

        // MARK: Latency
        if configuration.measuresLatency {
            do {
                let latency = try await withFallback(
                    endpoint: &endpoint,
                    fallback: configuration.fallbackEndpoint,
                    notes: &notes
                ) { target in
                    try await self.measureLatency(
                        endpoint: target,
                        samples: configuration.latencySampleCount,
                        timeout: configuration.requestTimeout
                    )
                }
                latencyMs = latency.latencyMs
                jitterMs = latency.jitterMs
            } catch {
                let classified = ErrorKind.classify(error)
                return .failure(
                    timestamp: startedAt,
                    endpointName: endpoint.name,
                    interface: interface,
                    kind: classified.kind,
                    detail: classified.detail,
                    duration: elapsed(),
                    note: note()
                )
            }
        }

        // MARK: Download
        do {
            let summary = try await withFallback(
                endpoint: &endpoint,
                fallback: configuration.fallbackEndpoint,
                notes: &notes
            ) { target in
                guard let url = target.downloadURL(bytes: configuration.downloadBytes) else {
                    throw ProbeError.invalidEndpoint(target.downloadURLTemplate)
                }
                let summary = try await TransferMeter().measureDownload(url: url, timeout: configuration.requestTimeout)
                try Self.validateDownload(
                    summary,
                    requestedBytes: configuration.downloadBytes,
                    isAdjustable: target.supportsAdjustableDownloadSize
                )
                return summary
            }
            downloadMbps = summary.megabitsPerSecond
            bytesDown = summary.totalBytes
        } catch {
            let classified = ErrorKind.classify(error)
            return ProbeResult(
                timestamp: startedAt,
                endpointName: endpoint.name,
                interface: interface,
                downloadMbps: nil,
                uploadMbps: nil,
                latencyMs: latencyMs,
                jitterMs: jitterMs,
                bytesDownloaded: 0,
                bytesUploaded: 0,
                duration: elapsed(),
                errorKind: classified.kind,
                errorDetail: classified.detail,
                note: note()
            )
        }

        // MARK: Upload
        // A failed upload does not invalidate a good download. A network-level
        // upload failure becomes the probe's error; a server-side refusal is
        // only noted, because the download already proved the line works.
        // The download may have fallen back to a server that cannot measure
        // upload at all. A server that refuses a 25 MB download often still
        // accepts a 5 MB POST — refusals are usually about download volume —
        // so upload goes to the configured endpoint whenever it supports it.
        let uploadEndpoint = Self.uploadEndpoint(configured: configuration.endpoint, downloadEndpoint: endpoint)
        if uploadEndpoint.id != endpoint.id, configuration.measuresUpload {
            notes.append("Upload measured against \(uploadEndpoint.name).")
        }

        var uploadFailure: (kind: ErrorKind, detail: String)?
        if configuration.measuresUpload {
            if let uploadURL = uploadEndpoint.uploadURL {
                do {
                    let payload = UploadPayload.make(byteCount: configuration.uploadBytes)
                    let summary = try await TransferMeter().measureUpload(
                        url: uploadURL,
                        payload: payload,
                        timeout: configuration.requestTimeout
                    )
                    try Self.validate(summary)
                    uploadMbps = summary.megabitsPerSecond
                    bytesUp = payload.count
                } catch let error as ProbeError where error.isServerSide {
                    recordBackOff(for: uploadEndpoint, after: error)
                    notes.append("Upload not measured: \(error.detail)")
                } catch {
                    uploadFailure = ErrorKind.classify(error)
                }
            } else {
                notes.append("Upload not measured: \(uploadEndpoint.name) does not support it.")
            }
        }

        // MARK: Threshold checks
        var thresholdFailure: (kind: ErrorKind, detail: String)?
        if let downloadMbps, downloadMbps < configuration.lowThroughputThresholdMbps {
            let error = ProbeError.belowThreshold(
                actual: downloadMbps,
                threshold: configuration.lowThroughputThresholdMbps
            )
            thresholdFailure = (error.kind, error.detail)
        } else if let latencyMs, latencyMs > configuration.highLatencyThresholdMs {
            let error = ProbeError.latencyAboveThreshold(
                actual: latencyMs,
                threshold: configuration.highLatencyThresholdMs
            )
            thresholdFailure = (error.kind, error.detail)
        }

        // A hard upload failure outranks a soft threshold breach in the log.
        let recordedFailure = uploadFailure ?? thresholdFailure

        return ProbeResult(
            timestamp: startedAt,
            endpointName: endpoint.name,
            interface: interface,
            downloadMbps: downloadMbps,
            uploadMbps: uploadMbps,
            latencyMs: latencyMs,
            jitterMs: jitterMs,
            bytesDownloaded: bytesDown,
            bytesUploaded: bytesUp,
            duration: elapsed(),
            errorKind: recordedFailure?.kind,
            errorDetail: recordedFailure?.detail,
            note: note()
        )
    }

    // MARK: - Reachability

    /// A cheap "is the internet there at all?" check, used while an outage is
    /// ongoing to notice recovery within seconds.
    ///
    /// Sends a HEAD request to the primary test point, then the fallback. Any
    /// HTTP response counts as reachable — even a 429 proves packets are
    /// getting out and back. Nothing is recorded; a positive answer just
    /// prompts the monitor to run a full probe.
    func isInternetReachable(configuration: ProbeConfiguration) async -> Bool {
        var candidates = [configuration.endpoint]
        if let fallback = configuration.fallbackEndpoint, fallback.id != configuration.endpoint.id {
            candidates.append(fallback)
        }
        for endpoint in candidates {
            if await answers(endpoint) {
                return true
            }
        }
        return false
    }

    private func answers(_ endpoint: TestEndpoint) async -> Bool {
        guard let url = endpoint.latencyURL() else { return false }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.urlCache = nil
        // Short: this runs repeatedly during an outage, and a slow "no" is
        // worth less than a quick one.
        sessionConfiguration.timeoutIntervalForRequest = 6
        sessionConfiguration.timeoutIntervalForResource = 6
        sessionConfiguration.waitsForConnectivity = false
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    // MARK: - Fallback

    /// Runs `operation` against `endpoint`. If that server answers but refuses,
    /// switches `endpoint` to the fallback for the rest of the probe and tries
    /// once more there.
    ///
    /// Network-level errors are rethrown untouched: a DNS failure or a timeout
    /// is exactly what this app exists to record, and papering over it with a
    /// second server would hide real outages.
    private func withFallback<T>(
        endpoint: inout TestEndpoint,
        fallback: TestEndpoint?,
        notes: inout [String],
        _ operation: (TestEndpoint) async throws -> T
    ) async throws -> T {
        do {
            return try await operation(endpoint)
        } catch let error as ProbeError where error.isServerSide {
            recordBackOff(for: endpoint, after: error)
            guard let fallback, fallback.id != endpoint.id else { throw error }
            notes.append("\(endpoint.name): \(error.detail) Used \(fallback.name) instead.")
            endpoint = fallback
            return try await operation(fallback)
        }
    }

    private func recordBackOff(for endpoint: TestEndpoint, after error: ProbeError, now: Date = Date()) {
        guard case .rateLimited(let retryAfter) = error else { return }
        let seconds = min(max(retryAfter ?? Self.defaultBackOff, 60), Self.maximumBackOff)
        backOffUntil[endpoint.id] = now.addingTimeInterval(seconds)
    }

    // MARK: - Pieces

    /// Picks where to POST the upload payload.
    ///
    /// The configured endpoint wins whenever it can measure upload, even if the
    /// download fell back to another server: throttling tends to apply to
    /// download volume, so the upload half of a probe usually still works.
    static func uploadEndpoint(configured: TestEndpoint, downloadEndpoint: TestEndpoint) -> TestEndpoint {
        configured.supportsUpload ? configured : downloadEndpoint
    }

    /// No honest throughput reading comes out of a transfer this small, whatever
    /// the endpoint's own size happens to be.
    static let minimumMeasurableBytes = 100_000

    private static func validate(_ summary: TransferSummary) throws {
        if let status = summary.statusCode, !(200..<300).contains(status) {
            throw ProbeError.forStatus(status, retryAfterHeader: summary.retryAfterHeader)
        }
        if summary.totalBytes == 0 {
            throw ProbeError.emptyResponse
        }
    }

    /// Rejects a download that did not actually deliver a payload.
    ///
    /// A throttling endpoint can answer `200 OK` with a couple of dozen bytes.
    /// Dividing that by the elapsed time yields ~0 Mbps, which then gets logged
    /// as "Low Throughput" — blaming the user's connection for the test
    /// server's refusal. Treating it as a server-side error instead sends the
    /// probe to the fallback endpoint, which can still measure the line.
    ///
    /// A little under the requested size is fine; endpoints round, and the
    /// fixed-size ones ignore the request entirely.
    static func validateDownload(_ summary: TransferSummary, requestedBytes: Int?, isAdjustable: Bool) throws {
        try validate(summary)

        if isAdjustable, let requestedBytes, requestedBytes > 0 {
            let required = Int(Double(requestedBytes) * 0.9)
            guard summary.totalBytes >= required else {
                throw ProbeError.shortResponse(expected: requestedBytes, received: summary.totalBytes)
            }
        } else {
            guard summary.totalBytes >= minimumMeasurableBytes else {
                throw ProbeError.shortResponse(expected: minimumMeasurableBytes, received: summary.totalBytes)
            }
        }
    }

    /// Times several small round trips and reports the best one.
    ///
    /// The minimum is used rather than the mean because a single sample that
    /// caught a busy moment says less about the line than the floor does.
    /// Jitter is the mean absolute difference between consecutive samples.
    /// These are HTTPS round trips, not ICMP pings — a little higher than
    /// `ping` would report, and comparable to each other over time.
    private func measureLatency(
        endpoint: TestEndpoint,
        samples sampleCount: Int,
        timeout: TimeInterval
    ) async throws -> (latencyMs: Double, jitterMs: Double?) {
        guard let url = endpoint.latencyURL() else {
            throw ProbeError.invalidEndpoint(endpoint.downloadURLTemplate)
        }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.timeoutIntervalForRequest = timeout
        sessionConfiguration.waitsForConnectivity = false
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.finishTasksAndInvalidate() }

        var samples: [Double] = []
        // One extra pass, discarded: it pays for DNS and the TLS handshake.
        let totalPasses = max(2, sampleCount + 1)

        for pass in 0..<totalPasses {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = endpoint.latencyUsesHEAD ? "HEAD" : "GET"
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

            let start = CFAbsoluteTimeGetCurrent()
            let (_, response) = try await session.data(for: request)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ProbeError.forStatus(
                    http.statusCode,
                    retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
                )
            }
            if pass > 0 {
                samples.append(elapsed)
            }
        }

        guard let best = samples.min() else {
            throw ProbeError.emptyResponse
        }

        var jitter: Double?
        if samples.count > 1 {
            var deltas: [Double] = []
            for index in 1..<samples.count {
                deltas.append(abs(samples[index] - samples[index - 1]))
            }
            jitter = deltas.reduce(0, +) / Double(deltas.count)
        }

        return (best, jitter)
    }
}
