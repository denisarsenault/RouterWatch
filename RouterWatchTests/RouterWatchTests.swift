//
//  RouterWatchTests.swift
//  RouterWatchTests
//

import SwiftUI
import XCTest
@testable import RouterWatch

final class ErrorClassificationTests: XCTestCase {

    func testURLErrorsMapToSpecificBuckets() {
        let cases: [(URLError.Code, ErrorKind)] = [
            (.cannotFindHost, .dnsFailure),
            (.dnsLookupFailed, .dnsFailure),
            (.cannotConnectToHost, .cannotConnect),
            (.networkConnectionLost, .connectionLost),
            (.timedOut, .timeout),
            (.secureConnectionFailed, .tlsFailure),
            (.serverCertificateUntrusted, .tlsFailure),
            (.notConnectedToInternet, .noNetworkPath),
            (.cancelled, .cancelled)
        ]

        for (code, expected) in cases {
            let error = NSError(domain: NSURLErrorDomain, code: code.rawValue)
            XCTAssertEqual(ErrorKind.classify(error).kind, expected, "code \(code.rawValue)")
        }
    }

    func testUnrecognisedURLErrorFallsBackToUnknown() {
        let error = NSError(domain: NSURLErrorDomain, code: URLError.Code.unknown.rawValue)
        XCTAssertEqual(ErrorKind.classify(error).kind, .unknown)
    }

    func testProbeErrorsCarryTheirOwnBucketAndDetail() {
        let belowFloor = ProbeError.belowThreshold(actual: 3.5, threshold: 10)
        let classified = ErrorKind.classify(belowFloor)
        XCTAssertEqual(classified.kind, .lowThroughput)
        XCTAssertTrue(classified.detail.contains("3.5"))

        XCTAssertEqual(ErrorKind.classify(ProbeError.httpStatus(503)).kind, .httpError)
        XCTAssertEqual(ErrorKind.classify(ProbeError.noNetworkPath).kind, .noNetworkPath)
    }

    func test429BecomesRateLimitedWithRetryAfter() {
        let error = ProbeError.forStatus(429, retryAfterHeader: " 3345 ")
        guard case .rateLimited(let retryAfter) = error else {
            return XCTFail("expected rateLimited, got \(error)")
        }
        XCTAssertEqual(retryAfter, 3345)
        XCTAssertEqual(error.kind, .rateLimited)
        XCTAssertTrue(error.isServerSide)
        XCTAssertTrue(error.detail.contains("56-minute"))
    }

    /// An HTTP-date Retry-After is legal but not parsed; the engine then uses
    /// its default back-off rather than failing.
    func testUnparseableRetryAfterIsIgnored() {
        guard case .rateLimited(let retryAfter) = ProbeError.forStatus(429, retryAfterHeader: "Wed, 21 Oct 2026 07:28:00 GMT") else {
            return XCTFail("expected rateLimited")
        }
        XCTAssertNil(retryAfter)
    }

    func testOtherStatusesStayHTTPErrors() {
        XCTAssertEqual(ProbeError.forStatus(403, retryAfterHeader: nil).kind, .httpError)
        XCTAssertEqual(ProbeError.forStatus(503, retryAfterHeader: "10").kind, .httpError)
    }

    func testNetworkErrorsAreNotServerSide() {
        XCTAssertFalse(ProbeError.noNetworkPath.isServerSide)
        XCTAssertFalse(ProbeError.belowThreshold(actual: 1, threshold: 10).isServerSide)
    }

    /// A server that answers — even with a refusal — proves the internet path
    /// works, so it must not count against availability.
    func testServerRefusalsAreNotOutages() {
        XCTAssertFalse(ErrorKind.httpError.isHardFailure)
        XCTAssertFalse(ErrorKind.rateLimited.isHardFailure)
    }

    func testDegradationsAreNotCountedAsHardFailures() {
        XCTAssertFalse(ErrorKind.lowThroughput.isHardFailure)
        XCTAssertFalse(ErrorKind.highLatency.isHardFailure)
        XCTAssertFalse(ErrorKind.cancelled.isHardFailure)
        XCTAssertTrue(ErrorKind.dnsFailure.isHardFailure)
        XCTAssertTrue(ErrorKind.noNetworkPath.isHardFailure)
    }
}

final class MonitorStatsTests: XCTestCase {

    private func success(_ mbps: Double, at date: Date = Date()) -> ProbeResult {
        ProbeResult(
            timestamp: date,
            endpointName: "Test",
            interface: .wired,
            downloadMbps: mbps,
            uploadMbps: mbps / 10,
            latencyMs: 20,
            jitterMs: 2,
            bytesDownloaded: 1_000_000,
            bytesUploaded: 100_000,
            duration: 1
        )
    }

    private func failure(_ kind: ErrorKind, at date: Date = Date()) -> ProbeResult {
        .failure(timestamp: date, endpointName: "Test", interface: .wired, kind: kind, detail: "detail")
    }

    func testEmptyInputProducesEmptyStats() {
        let stats = MonitorStats.compute(from: [])
        XCTAssertEqual(stats.sampleCount, 0)
        XCTAssertEqual(stats.successRate, 0)
        XCTAssertNil(stats.averageDownloadMbps)
        XCTAssertTrue(stats.errorTallies.isEmpty)
    }

    func testMedianForOddAndEvenCounts() {
        let odd = MonitorStats.compute(from: [success(10), success(30), success(20)])
        XCTAssertEqual(odd.medianDownloadMbps, 20)

        let even = MonitorStats.compute(from: [success(10), success(20), success(30), success(40)])
        XCTAssertEqual(even.medianDownloadMbps, 25)
    }

    func testMinMaxAndAverage() {
        let stats = MonitorStats.compute(from: [success(10), success(50), success(30)])
        XCTAssertEqual(stats.minDownloadMbps, 10)
        XCTAssertEqual(stats.maxDownloadMbps, 50)
        XCTAssertEqual(stats.averageDownloadMbps ?? 0, 30, accuracy: 0.0001)
    }

    /// A slow-but-working link counts against the success rate but not against
    /// availability — the distinction the dashboard is built on.
    func testAvailabilityExcludesSoftFailuresWhileSuccessRateDoesNot() {
        let results = [
            success(50),
            failure(.lowThroughput),
            failure(.dnsFailure),
            success(50)
        ]
        let stats = MonitorStats.compute(from: results)
        XCTAssertEqual(stats.sampleCount, 4)
        XCTAssertEqual(stats.failureCount, 2)
        XCTAssertEqual(stats.outageCount, 1)
        XCTAssertEqual(stats.successRate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(stats.availability, 0.75, accuracy: 0.0001)
    }

    func testTalliesAreSortedByCountAndOnlyIncludeObservedKinds() {
        let results = [
            failure(.timeout),
            failure(.timeout),
            failure(.timeout),
            failure(.dnsFailure),
            failure(.dnsFailure),
            failure(.tlsFailure),
            success(10)
        ]
        let tallies = MonitorStats.tally(results)
        XCTAssertEqual(tallies.map(\.kind), [.timeout, .dnsFailure, .tlsFailure])
        XCTAssertEqual(tallies.map(\.count), [3, 2, 1])
    }
}

final class TimeRangeTests: XCTestCase {

    func testAllTimeHasNoLowerBound() {
        XCTAssertNil(TimeRange.all.startDate())
    }

    func testWindowsAreMeasuredBackFromNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(TimeRange.hour24.startDate(now: now), now.addingTimeInterval(-86_400))
        XCTAssertEqual(TimeRange.days7.startDate(now: now), now.addingTimeInterval(-7 * 86_400))
    }
}

final class TransferSummaryTests: XCTestCase {

    func testThroughputUsesTheWarmWindowWhenOneExists() {
        // 12.5 MB in 1 second is 100 Mbps.
        let summary = TransferSummary(
            totalBytes: 25_000_000,
            measuredBytes: 12_500_000,
            measuredSeconds: 1,
            totalSeconds: 3,
            statusCode: 200
        )
        XCTAssertEqual(summary.megabitsPerSecond, 100, accuracy: 0.001)
    }

    /// Short transfers can finish inside the warm-up window; the whole transfer
    /// is used rather than reporting nothing.
    func testThroughputFallsBackToTheWholeTransfer() {
        let summary = TransferSummary(
            totalBytes: 1_000_000,
            measuredBytes: 0,
            measuredSeconds: 0,
            totalSeconds: 0.5,
            statusCode: 200
        )
        XCTAssertEqual(summary.megabitsPerSecond, 16, accuracy: 0.001)
    }

    func testZeroLengthTransferReportsZeroRatherThanInfinity() {
        let summary = TransferSummary(
            totalBytes: 0,
            measuredBytes: 0,
            measuredSeconds: 0,
            totalSeconds: 0,
            statusCode: 204
        )
        XCTAssertEqual(summary.megabitsPerSecond, 0)
    }
}

final class DownloadValidationTests: XCTestCase {

    private func summary(bytes: Int, status: Int = 200) -> TransferSummary {
        TransferSummary(totalBytes: bytes, measuredBytes: bytes, measuredSeconds: 1, totalSeconds: 1, statusCode: status)
    }

    /// The observed failure: a throttling endpoint answers 200 OK with 24
    /// bytes. That is a refusal, not a 0 Mbps connection.
    func testTinyResponseToASizedRequestIsRejected() {
        XCTAssertThrowsError(
            try SpeedTestEngine.validateDownload(summary(bytes: 24), requestedBytes: 25_000_000, isAdjustable: true)
        ) { error in
            guard case ProbeError.shortResponse(let expected, let received) = error else {
                return XCTFail("expected shortResponse, got \(error)")
            }
            XCTAssertEqual(expected, 25_000_000)
            XCTAssertEqual(received, 24)
            // Server-side, so the probe falls back instead of blaming the line.
            XCTAssertTrue((error as! ProbeError).isServerSide)
            XCTAssertEqual((error as! ProbeError).kind, .httpError)
        }
    }

    func testFullPayloadIsAccepted() throws {
        try SpeedTestEngine.validateDownload(summary(bytes: 25_000_000), requestedBytes: 25_000_000, isAdjustable: true)
        // Endpoints that round down slightly are still fine.
        try SpeedTestEngine.validateDownload(summary(bytes: 24_000_000), requestedBytes: 25_000_000, isAdjustable: true)
    }

    /// Fixed-size endpoints ignore the requested size, so they are judged
    /// against a floor instead.
    func testFixedSizeEndpointIsJudgedAgainstAFloor() throws {
        try SpeedTestEngine.validateDownload(summary(bytes: 10_485_760), requestedBytes: 10_000_000, isAdjustable: false)
        XCTAssertThrowsError(
            try SpeedTestEngine.validateDownload(summary(bytes: 512), requestedBytes: 10_000_000, isAdjustable: false)
        )
    }

    func testStatusAndEmptyChecksStillApply() {
        XCTAssertThrowsError(try SpeedTestEngine.validateDownload(summary(bytes: 25_000_000, status: 429), requestedBytes: 25_000_000, isAdjustable: true))
        XCTAssertThrowsError(try SpeedTestEngine.validateDownload(summary(bytes: 0), requestedBytes: 25_000_000, isAdjustable: true))
    }
}

final class UploadEndpointTests: XCTestCase {

    /// The reported symptom: upload showed "—" because the download fell back
    /// to CacheFly, which has no upload endpoint.
    func testUploadStaysOnTheConfiguredServerWhenTheDownloadFallsBack() {
        let chosen = SpeedTestEngine.uploadEndpoint(configured: .cloudflare, downloadEndpoint: .cachefly)
        XCTAssertEqual(chosen.id, TestEndpoint.cloudflare.id)
        XCTAssertNotNil(chosen.uploadURL)
    }

    func testFallbackIsUsedWhenTheConfiguredServerCannotUpload() {
        let chosen = SpeedTestEngine.uploadEndpoint(configured: .cachefly, downloadEndpoint: .cloudflare)
        XCTAssertEqual(chosen.id, TestEndpoint.cloudflare.id)
    }

    func testCustomEndpointWithoutUploadFallsBackToTheDownloadServer() {
        let custom = TestEndpoint.custom(downloadURLString: "https://example.com/file.bin")
        XCTAssertEqual(SpeedTestEngine.uploadEndpoint(configured: custom, downloadEndpoint: custom).id, custom.id)
    }
}

final class UploadTimingTests: XCTestCase {

    /// Uploads are timed to completion, not to the moment the kernel accepted
    /// the bytes — otherwise a 5 MB upload on a 23 Mbps link reads as 100+ Mbps.
    func testUploadThroughputUsesTheWholeTransfer() {
        // 5 MB that took 1.74 s is ~23 Mbps.
        let summary = TransferSummary(
            totalBytes: 5_000_000,
            measuredBytes: 5_000_000,
            measuredSeconds: 1.74,
            totalSeconds: 1.74,
            statusCode: 200
        )
        XCTAssertEqual(summary.megabitsPerSecond, 22.99, accuracy: 0.05)
    }

    /// The old behaviour, for contrast: the same payload "sent" in 0.34 s —
    /// the time it takes to fill a socket buffer — reads as 117 Mbps.
    func testSocketBufferTimingWouldHaveOverstatedIt() {
        let summary = TransferSummary(
            totalBytes: 5_000_000,
            measuredBytes: 5_000_000,
            measuredSeconds: 0.34,
            totalSeconds: 0.34,
            statusCode: 200
        )
        XCTAssertGreaterThan(summary.megabitsPerSecond, 100)
    }
}

final class UploadPayloadTests: XCTestCase {

    func testPayloadIsExactlyTheRequestedSize() {
        XCTAssertEqual(UploadPayload.make(byteCount: 0).count, 0)
        XCTAssertEqual(UploadPayload.make(byteCount: 1_000).count, 1_000)
        XCTAssertEqual(UploadPayload.make(byteCount: 100_000).count, 100_000)
        XCTAssertEqual(UploadPayload.make(byteCount: 1_000_000).count, 1_000_000)
    }
}

final class TestEndpointTests: XCTestCase {

    func testPlaceholderIsSubstituted() {
        let url = TestEndpoint.cloudflare.downloadURL(bytes: 25_000_000)
        XCTAssertEqual(url?.absoluteString, "https://speed.cloudflare.com/__down?bytes=25000000")
    }

    func testFixedSizeEndpointIgnoresTheRequestedSize() {
        XCTAssertFalse(TestEndpoint.cachefly.supportsAdjustableDownloadSize)
        XCTAssertEqual(
            TestEndpoint.cachefly.downloadURL(bytes: 999)?.absoluteString,
            "https://cachefly.cachefly.net/10mb.test"
        )
    }

    func testFixedSizeEndpointsMeasureLatencyWithHEAD() {
        XCTAssertTrue(TestEndpoint.cachefly.latencyUsesHEAD)
        XCTAssertFalse(TestEndpoint.cloudflare.latencyUsesHEAD)
    }

    func testLatencyFallsBackToAZeroByteDownload() {
        XCTAssertEqual(
            TestEndpoint.cachefly.latencyURL()?.absoluteString,
            "https://cachefly.cachefly.net/10mb.test"
        )
        XCTAssertEqual(
            TestEndpoint.cloudflare.latencyURL()?.absoluteString,
            "https://speed.cloudflare.com/__down?bytes=0"
        )
    }
}

final class ExportServiceTests: XCTestCase {

    func testCSVHasAHeaderAndOneRowPerResult() {
        let results = [
            ProbeResult(
                timestamp: Date(timeIntervalSince1970: 0),
                endpointName: "Cloudflare",
                interface: .wifi,
                downloadMbps: 94.5,
                uploadMbps: 9.5,
                latencyMs: 18,
                jitterMs: 2,
                bytesDownloaded: 25_000_000,
                bytesUploaded: 5_000_000,
                duration: 4.2
            )
        ]
        let lines = ExportService.csv(from: results, networkName: "Home").split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("timestamp,network,endpoint,interface"))
        XCTAssertTrue(lines[1].contains(",Home,Cloudflare,"))
        XCTAssertTrue(lines[1].contains("94.50"))
    }

    func testFieldsContainingCommasAreQuoted() {
        let result = ProbeResult.failure(
            endpointName: "Cloudflare",
            interface: .wired,
            kind: .timeout,
            detail: "Timed out, then gave up"
        )
        let csv = ExportService.csv(from: [result], networkName: "Home")
        XCTAssertTrue(csv.contains("\"Timed out, then gave up\""))
    }

    func testFilenameIdentifiesTheNetworkSafely() {
        let name = ExportService.suggestedFilename(
            networkName: "Charter Communications Inc · 192.168.1.1",
            extension: "csv",
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(name.hasPrefix("RouterWatch-Charter-Communications-Inc-192.168.1.1-"), name)
        XCTAssertFalse(name.contains(" "))
        XCTAssertTrue(name.hasSuffix(".csv"))
    }

    func testEmbeddedQuotesAreDoubled() {
        let result = ProbeResult.failure(
            endpointName: "Cloudflare",
            interface: .wired,
            kind: .unknown,
            detail: "Server said \"no\""
        )
        let csv = ExportService.csv(from: [result], networkName: "Home")
        XCTAssertTrue(csv.contains("\"Server said \"\"no\"\"\""))
    }
}

@MainActor
final class MeasurementStoreTests: XCTestCase {

    private func makeStore() -> MeasurementStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("routerwatch-tests-\(UUID().uuidString).json")
        return MeasurementStore(fileURL: url)
    }

    func testPruneDropsOnlyEntriesOlderThanTheWindow() {
        let store = makeStore()
        let now = Date()
        store.append(
            .failure(timestamp: now.addingTimeInterval(-40 * 86_400), endpointName: "T", interface: .wired, kind: .timeout, detail: ""),
            retentionDays: 3650
        )
        store.append(
            .failure(timestamp: now.addingTimeInterval(-1 * 86_400), endpointName: "T", interface: .wired, kind: .timeout, detail: ""),
            retentionDays: 3650
        )
        XCTAssertEqual(store.results.count, 2)

        let removed = store.prune(retentionDays: 30, now: now)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(store.results.count, 1)
    }

    func testRangeQueryFiltersByTimestamp() {
        let store = makeStore()
        let now = Date()
        store.append(
            .failure(timestamp: now.addingTimeInterval(-3 * 86_400), endpointName: "T", interface: .wired, kind: .timeout, detail: ""),
            retentionDays: 3650
        )
        store.append(
            .failure(timestamp: now.addingTimeInterval(-60 * 60), endpointName: "T", interface: .wired, kind: .dnsFailure, detail: ""),
            retentionDays: 3650
        )

        XCTAssertEqual(store.results(in: .hour24, now: now).count, 1)
        XCTAssertEqual(store.results(in: .days7, now: now).count, 2)
        XCTAssertEqual(store.results(in: .all, now: now).count, 2)
    }

    /// Logs written before `note` existed must still load.
    func testResultsWithoutNoteFieldStillDecode() throws {
        let legacy = """
        [{"id":"6BCA2EFB-27B5-40D9-85F5-E40365E07D1D","timestamp":"2026-09-16T02:12:07Z",
          "endpointName":"Cloudflare Speed Test","interface":"wifi","downloadMbps":93.1,
          "bytesDownloaded":25000000,"bytesUploaded":0,"duration":7.4}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let results = try decoder.decode([ProbeResult].self, from: Data(legacy.utf8))
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].note)
    }

    /// Clearing the false readings a throttled server produced, without
    /// touching results from a genuinely slow connection.
    func testRefusalArtifactsAreRemovedAndRealSlowResultsKept() {
        let store = makeStore()

        // What a throttled endpoint produced: 200 OK, 24 bytes, ~0 Mbps,
        // logged as Low Throughput.
        var artifact = ProbeResult(
            timestamp: Date(),
            endpointName: "Cloudflare Speed Test",
            interface: .wifi,
            downloadMbps: 0,
            bytesDownloaded: 24,
            bytesUploaded: 0,
            duration: 1
        )
        artifact.errorKind = .lowThroughput
        artifact.errorDetail = "Download measured 0.0 Mbps, below the 10 Mbps floor."
        store.append(artifact, retentionDays: 0)

        // A real slow test: the whole 10 MB moved, just slowly.
        var genuinelySlow = ProbeResult(
            timestamp: Date(),
            endpointName: "CacheFly (10 MB)",
            interface: .wifi,
            downloadMbps: 1.9,
            bytesDownloaded: 10_485_760,
            bytesUploaded: 0,
            duration: 44
        )
        genuinelySlow.errorKind = .lowThroughput
        store.append(genuinelySlow, retentionDays: 0)

        // A real outage: no download recorded at all.
        store.append(
            .failure(endpointName: "Cloudflare Speed Test", interface: .wifi, kind: .timeout, detail: ""),
            retentionDays: 0
        )

        XCTAssertEqual(store.removeRefusalArtifacts(), 1)
        XCTAssertEqual(store.results.count, 2)
        XCTAssertEqual(store.results.first?.downloadMbps, 1.9)
        XCTAssertEqual(store.results.last?.errorKind, .timeout)
        XCTAssertEqual(store.removeRefusalArtifacts(), 0, "nothing left to remove")
    }

    func testRetentionOfZeroKeepsEverything() {
        let store = makeStore()
        store.append(
            .failure(timestamp: Date(timeIntervalSince1970: 0), endpointName: "T", interface: .wired, kind: .timeout, detail: ""),
            retentionDays: 0
        )
        XCTAssertEqual(store.results.count, 1)
    }
}

// MARK: - Recovery detection

/// Stands in for `SpeedTestEngine`: hands out scripted results and a
/// switchable "is the internet reachable" answer, and counts calls.
actor ScriptedEngine: ProbeRunning {
    private var results: [ProbeResult]
    private var reachable: Bool
    private(set) var runCount = 0
    private(set) var reachabilityChecks = 0

    /// Results are handed out in order; the last one repeats.
    init(results: [ProbeResult], reachable: Bool = false) {
        self.results = results
        self.reachable = reachable
    }

    private var whileRunning: (@Sendable () async -> Void)?
    private var runDelay: UInt64 = 0
    private var currentRouter: (@Sendable () async -> String?)?

    /// Lets a test stamp each result with the router it was really measured
    /// on, which is what cross-filing has to be checked against.
    func setCurrentRouter(_ reader: @escaping @Sendable () async -> String?) {
        currentRouter = reader
    }

    func run(configuration: ProbeConfiguration, interface: InterfaceKind, hasNetworkPath: Bool) async -> ProbeResult {
        runCount += 1
        var result = results.count > 1 ? results.removeFirst() : results[0]
        result.id = UUID()
        result.timestamp = Date()
        if runDelay > 0 {
            try? await Task.sleep(nanoseconds: runDelay)
        }
        // Simulates something happening mid-test, like joining another network.
        if let hook = whileRunning {
            whileRunning = nil
            await hook()
        }
        if let currentRouter {
            result.endpointName = "measured-on:" + (await currentRouter() ?? "none")
        }
        return result
    }

    /// Runs once, during the next probe, before it returns.
    func setWhileRunning(_ hook: @escaping @Sendable () async -> Void) {
        whileRunning = hook
    }

    func setRunDelay(nanoseconds: UInt64) {
        runDelay = nanoseconds
    }

    /// Swaps in the results for the next probes.
    func setResults(_ newResults: [ProbeResult]) {
        results = newResults
    }

    func isInternetReachable(configuration: ProbeConfiguration) async -> Bool {
        reachabilityChecks += 1
        return reachable
    }

    func setReachable(_ value: Bool) {
        reachable = value
    }
}

/// Stands in for `NetworkIdentifier`: a fixed ISP per router address.
actor FakeIdentifier: NetworkIdentifying {
    private var byGateway: [String: ISPInfo]

    init(_ byGateway: [String: ISPInfo]) {
        self.byGateway = byGateway
    }

    func ispInfo(gatewayIP: String?, interface: InterfaceKind) async -> ISPInfo? {
        gatewayIP.flatMap { byGateway[$0] }
    }

    /// Simulates the lookup failing, as it does when the internet is down.
    func forgetAll() {
        byGateway = [:]
    }
}

extension ISPInfo {
    static let charter = ISPInfo(asn: 33363, organization: "Charter Communications Inc", publicIP: "67.8.88.85", city: "Deltona", region: "Florida", country: "US")
    static let att = ISPInfo(asn: 7018, organization: "AT&T Enterprises, LLC", publicIP: "12.0.0.1", city: "Orlando", region: "Florida", country: "US")
    static let tmobile = ISPInfo(asn: 21928, organization: "T-Mobile USA, Inc.", publicIP: "172.56.0.1", city: nil, region: nil, country: "US")
}

@MainActor
struct MonitorHarness {
    let monitor: MonitorController
    let path: NetworkPathMonitor
    let networks: NetworkLibrary
    let root: URL
    static let homeRouter = "192.168.1.1"
    static let officeRouter = "10.0.0.1"

    static let fastTiming = MonitorTiming(
        tick: 0.01,
        recoveryCheckInterval: 0.05,
        pathDownSettle: 0.03,
        pathUpSettle: 0.03
    )

    /// A monitor with a 15-minute schedule, so any probe after the first must
    /// have come from recovery or network-change detection, not the timer.
    /// Starts on the home router.
    init(
        engine: ScriptedEngine,
        identifier: FakeIdentifier = FakeIdentifier([homeRouter: .charter, officeRouter: .att]),
        reportsInitialPath: Bool = true
    ) {
        let defaults = UserDefaults(suiteName: "routerwatch-tests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.intervalMinutes = 15
        settings.notifiesOnFailure = false

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("routerwatch-tests-\(UUID().uuidString)", isDirectory: true)
        networks = NetworkLibrary(rootDirectory: root)
        networks.load()

        path = NetworkPathMonitor()
        if reportsInitialPath {
            path.apply(isSatisfied: true, interface: .wifi, gatewayIP: Self.homeRouter)
        }

        monitor = MonitorController(
            settings: settings,
            networks: networks,
            pathMonitor: path,
            notifications: NotificationService(),
            engine: engine,
            identifier: identifier,
            timing: Self.fastTiming
        )
    }
}

@MainActor
func waitUntil(
    timeout: TimeInterval = 3,
    _ description: String,
    _ condition: () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for: \(description)")
    throw CancellationError()
}

func outageResult(_ kind: ErrorKind = .timeout) -> ProbeResult {
    .failure(endpointName: "Test", interface: .wifi, kind: kind, detail: "down")
}

func successResult() -> ProbeResult {
    ProbeResult(
        timestamp: Date(),
        endpointName: "Test",
        interface: .wifi,
        downloadMbps: 90,
        uploadMbps: 20,
        latencyMs: 30,
        jitterMs: 2,
        bytesDownloaded: 25_000_000,
        bytesUploaded: 5_000_000,
        duration: 3
    )
}

@MainActor
final class MonitorRecoveryTests: XCTestCase {

    /// The reported bug: the router drops the internet while Wi-Fi stays up.
    /// Nothing tells the path monitor, so recovery has to be found by polling.
    func testRecoveryIsDetectedByPollingWhileInterfaceStaysUp() async throws {
        let engine = ScriptedEngine(results: [outageResult(), successResult()], reachable: false)
        let h = MonitorHarness(engine: engine)
        h.monitor.start()
        defer { h.monitor.stop() }

        try await waitUntil("first probe") { await engine.runCount == 1 }
        XCTAssertEqual(h.monitor.health, .down)
        XCTAssertNotNil(h.monitor.outageStartedAt)

        // Still down: checks run, but no full probe is spent on them.
        try await waitUntil("several reachability checks") { await engine.reachabilityChecks >= 3 }
        let runsWhileDown = await engine.runCount
        XCTAssertEqual(runsWhileDown, 1)

        await engine.setReachable(true)
        try await waitUntil("recovery probe") { await engine.runCount == 2 }

        XCTAssertEqual(h.monitor.health, .healthy)
        XCTAssertNil(h.monitor.outageStartedAt)
        let store = h.networks.activeStore
        XCTAssertEqual(store.results.count, 2)
        XCTAssertTrue(store.results.last?.note?.hasPrefix("Back online after") == true)
    }

    /// Wi-Fi drops and comes back: the returning path triggers a test directly,
    /// without waiting for a reachability poll.
    func testReturningNetworkPathTriggersImmediateTest() async throws {
        let engine = ScriptedEngine(results: [outageResult(.noNetworkPath), successResult()], reachable: false)
        let h = MonitorHarness(engine: engine)
        h.monitor.start()
        defer { h.monitor.stop() }

        try await waitUntil("first probe") { await engine.runCount == 1 }

        h.path.apply(isSatisfied: false, interface: .wifi)
        // Already recorded as down, so losing the path must not add a probe;
        // and with no path, reachability polling must stay idle.
        try await Task.sleep(nanoseconds: 150_000_000)
        let runsWhileOffline = await engine.runCount
        let checksWhileOffline = await engine.reachabilityChecks
        XCTAssertEqual(runsWhileOffline, 1)
        XCTAssertEqual(checksWhileOffline, 0)

        h.path.apply(isSatisfied: true, interface: .wifi, gatewayIP: MonitorHarness.homeRouter)
        try await waitUntil("probe after path returns") { await engine.runCount == 2 }
        XCTAssertEqual(h.monitor.health, .healthy)
    }

    /// Losing the network while the log says "up" records the outage straight
    /// away rather than at the next scheduled test.
    func testLosingNetworkPathRecordsOutageImmediately() async throws {
        let engine = ScriptedEngine(results: [successResult(), outageResult(.noNetworkPath)])
        let h = MonitorHarness(engine: engine)
        h.monitor.start()
        defer { h.monitor.stop() }

        try await waitUntil("first probe") { await engine.runCount == 1 }
        XCTAssertEqual(h.monitor.health, .healthy)

        h.path.apply(isSatisfied: false, interface: .wifi)
        try await waitUntil("probe after path loss") { await engine.runCount == 2 }
        XCTAssertEqual(h.monitor.health, .down)
    }

    /// A Wi-Fi roam that drops and restores the path inside the settle window
    /// must not log a phantom outage.
    func testBriefPathBlipIsIgnored() async throws {
        let engine = ScriptedEngine(results: [successResult()])
        let h = MonitorHarness(engine: engine)
        h.monitor.start()
        defer { h.monitor.stop() }

        try await waitUntil("first probe") { await engine.runCount == 1 }
        h.path.apply(isSatisfied: false, interface: .wifi)
        h.path.apply(isSatisfied: true, interface: .wifi, gatewayIP: MonitorHarness.homeRouter)
        try await Task.sleep(nanoseconds: 150_000_000)

        let runs = await engine.runCount
        XCTAssertEqual(runs, 1)
    }

    /// A relaunch mid-outage still knows it is in one, and still reports the
    /// full downtime when it ends.
    func testOutageInProgressAtLaunchIsRecognised() async throws {
        let engine = ScriptedEngine(results: [outageResult(), successResult()], reachable: true)
        let h = MonitorHarness(engine: engine)
        let home = h.networks.resolve(NetworkObservation(interface: .wifi, gatewayIP: MonitorHarness.homeRouter, isp: .charter))
        let began = Date().addingTimeInterval(-600)
        h.networks.store(for: home.id).append(
            .failure(timestamp: began, endpointName: "Test", interface: .wifi, kind: .dnsFailure, detail: ""),
            retentionDays: 0
        )

        h.monitor.start()
        defer { h.monitor.stop() }
        XCTAssertEqual(h.monitor.outageStartedAt, began)

        try await waitUntil("recovery probe") { await engine.runCount == 2 }
        let note = try XCTUnwrap(h.networks.store(for: home.id).results.last?.note)
        XCTAssertTrue(note.contains("Back online after 10m"), note)
    }

    /// An outage left over from days ago — the laptop was elsewhere, or asleep —
    /// must not produce a "back online after 3 days" claim nobody can verify.
    func testStaleOutageIsNotReportedAsRecovery() async throws {
        let engine = ScriptedEngine(results: [successResult()])
        let h = MonitorHarness(engine: engine)
        let home = h.networks.resolve(NetworkObservation(interface: .wifi, gatewayIP: MonitorHarness.homeRouter, isp: .charter))
        h.networks.store(for: home.id).append(
            .failure(timestamp: Date().addingTimeInterval(-3 * 86_400), endpointName: "Test", interface: .wifi, kind: .timeout, detail: ""),
            retentionDays: 0
        )

        h.monitor.start()
        defer { h.monitor.stop() }

        try await waitUntil("first probe") { await engine.runCount == 1 }
        XCTAssertNil(h.networks.store(for: home.id).results.last?.note)
    }
}

@MainActor
final class MonitorNetworkTests: XCTestCase {

    /// The feature: moving to another network files new results in that
    /// network's own log, and each is identified.
    func testResultsAreFiledUnderTheNetworkTheyWereMeasuredOn() async throws {
        let engine = ScriptedEngine(results: [successResult()])
        let h = MonitorHarness(engine: engine)
        h.monitor.start()
        defer { h.monitor.stop() }

        try await waitUntil("probe on home network") { await engine.runCount == 1 }
        let home = try XCTUnwrap(h.networks.activeProfile)
        XCTAssertEqual(home.isp?.asn, ISPInfo.charter.asn)
        XCTAssertEqual(home.displayName, "Charter Communications Inc · 192.168.1.1")

        // Joining another Wi-Fi network without ever going offline.
        h.path.apply(isSatisfied: true, interface: .wifi, gatewayIP: MonitorHarness.officeRouter)
        try await waitUntil("probe after switching networks") { await engine.runCount == 2 }

        let office = try XCTUnwrap(h.networks.activeProfile)
        XCTAssertNotEqual(office.id, home.id)
        XCTAssertEqual(office.isp?.asn, ISPInfo.att.asn)
        XCTAssertEqual(h.networks.profiles.count, 2)

        let homeResults = h.networks.store(for: home.id).results
        let officeResults = h.networks.store(for: office.id).results
        XCTAssertEqual(homeResults.count, 1)
        XCTAssertEqual(officeResults.count, 1)
        XCTAssertEqual(homeResults.first?.networkID, home.id)
        XCTAssertEqual(officeResults.first?.networkID, office.id)

        // And they really are separate files.
        h.networks.flushPendingWrites()
        let homeFile = h.root.appendingPathComponent("Networks/\(home.id)/measurements.json")
        let officeFile = h.root.appendingPathComponent("Networks/\(office.id)/measurements.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: homeFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: officeFile.path))
    }

    /// With no network at all, the outage belongs to the network the device
    /// was just on — not to a new "unknown" network.
    func testOfflineOutageIsFiledUnderTheLastNetwork() async throws {
        let engine = ScriptedEngine(results: [successResult(), outageResult(.noNetworkPath)])
        let h = MonitorHarness(engine: engine)
        h.monitor.start()
        defer { h.monitor.stop() }

        try await waitUntil("first probe") { await engine.runCount == 1 }
        let home = try XCTUnwrap(h.networks.activeProfile)

        h.path.apply(isSatisfied: false, interface: .wifi)
        try await waitUntil("outage probe") { await engine.runCount == 2 }

        XCTAssertEqual(h.networks.profiles.count, 1)
        XCTAssertEqual(h.networks.store(for: home.id).results.map(\.isOutage), [false, true])
    }

    /// Router up but internet down: the ISP cannot be looked up, yet the
    /// result still lands on the right network by router address.
    func testWANOutageWithoutISPLookupStaysOnTheSameNetwork() async throws {
        let engine = ScriptedEngine(results: [successResult(), outageResult(.cannotConnect)])
        let identifier = FakeIdentifier([MonitorHarness.homeRouter: .charter])
        let h = MonitorHarness(engine: engine, identifier: identifier)
        h.monitor.start()
        defer { h.monitor.stop() }

        try await waitUntil("first probe") { await engine.runCount == 1 }
        let home = try XCTUnwrap(h.networks.activeProfile)

        // The real identifier would fall back to its cache; test the worst
        // case, where no provider information is available at all.
        await identifier.forgetAll()
        h.monitor.runNow()
        try await waitUntil("second probe") { await engine.runCount == 2 }

        XCTAssertEqual(h.networks.profiles.count, 1)
        XCTAssertEqual(h.networks.store(for: home.id).results.count, 2)
    }
}

/// Switching networks must never let one network's results land in, or
/// overwrite, another network's log.
@MainActor
final class NetworkIsolationTests: XCTestCase {

    /// Every result in every network's log carries that network's ID.
    private func assertEveryResultIsInItsOwnNetwork(_ networks: NetworkLibrary, file: StaticString = #filePath, line: UInt = #line) {
        for profile in networks.profiles {
            for result in networks.store(for: profile.id).results {
                XCTAssertEqual(result.networkID, profile.id, "a result from another network is in \(profile.displayName)", file: file, line: line)
            }
        }
    }

    /// The core bug: a probe takes up to a minute. Joining another network
    /// partway through used to file the new network's measurement under the
    /// network the probe started on.
    func testSwitchingNetworksMidTestNeverFilesUnderTheOldNetwork() async throws {
        let engine = ScriptedEngine(results: [successResult()])
        let h = MonitorHarness(engine: engine)
        let path = h.path
        await engine.setWhileRunning {
            await MainActor.run {
                path.apply(isSatisfied: true, interface: .wifi, gatewayIP: MonitorHarness.officeRouter)
            }
        }

        h.monitor.start()
        defer { h.monitor.stop() }

        try await waitUntil("the office network gets its own clean measurement") {
            h.networks.profiles.contains { $0.isp?.asn == ISPInfo.att.asn }
                && !h.networks.activeStore.results.isEmpty
        }

        let home = try XCTUnwrap(h.networks.profiles.first { $0.isp?.asn == ISPInfo.charter.asn })
        let office = try XCTUnwrap(h.networks.profiles.first { $0.isp?.asn == ISPInfo.att.asn })
        XCTAssertTrue(h.networks.store(for: home.id).results.isEmpty, "the mixed measurement must not land on the home network")
        XCTAssertFalse(h.networks.store(for: office.id).results.isEmpty)
        XCTAssertEqual(h.monitor.discardedProbeCount, 1)
        assertEveryResultIsInItsOwnNetwork(h.networks)
    }

    /// Away and back within one test — home to a phone hotspot and home again.
    /// The router is the same at both ends, but part of the measurement was
    /// taken on the hotspot, so it belongs to neither log.
    func testRoundTripToAnotherNetworkWithinOneTestIsDiscarded() async throws {
        let engine = ScriptedEngine(results: [successResult()])
        let h = MonitorHarness(engine: engine)
        let path = h.path
        await engine.setWhileRunning {
            await MainActor.run {
                path.apply(isSatisfied: true, interface: .wifi, gatewayIP: MonitorHarness.officeRouter)
                path.apply(isSatisfied: true, interface: .wifi, gatewayIP: MonitorHarness.homeRouter)
            }
        }

        let first = await h.monitor.probeOnce()

        XCTAssertEqual(h.monitor.discardedProbeCount, 1)
        XCTAssertEqual(first.note, "Not recorded: this device changed networks during the test.")
        XCTAssertTrue(h.networks.activeStore.results.isEmpty)

        // A clean test afterwards is recorded normally.
        await h.monitor.probeOnce()
        XCTAssertEqual(h.networks.activeStore.results.count, 1)
    }

    /// Dropping off and rejoining the same router is not a network change;
    /// that test's result still belongs to this network.
    func testRejoiningTheSameRouterKeepsTheResult() async throws {
        let engine = ScriptedEngine(results: [successResult()])
        let h = MonitorHarness(engine: engine)
        let path = h.path
        await engine.setWhileRunning {
            await MainActor.run {
                path.apply(isSatisfied: false, interface: .wifi)
                path.apply(isSatisfied: true, interface: .wifi, gatewayIP: MonitorHarness.homeRouter)
            }
        }

        await h.monitor.probeOnce()

        XCTAssertEqual(h.monitor.discardedProbeCount, 0)
        XCTAssertEqual(h.networks.activeStore.results.count, 1)
    }

    /// Deleting the network mid-test must not bring its folder back.
    func testDeletingTheNetworkMidTestDoesNotResurrectIt() async throws {
        let engine = ScriptedEngine(results: [successResult()])
        let h = MonitorHarness(engine: engine)
        let networks = h.networks
        var deletedID: String?
        await engine.setWhileRunning {
            await MainActor.run {
                deletedID = networks.activeNetworkID
                if let id = deletedID { networks.delete(id) }
            }
        }

        h.monitor.start()
        defer { h.monitor.stop() }

        try await waitUntil("a fresh network is measured") {
            !networks.profiles.isEmpty && !networks.activeStore.results.isEmpty
        }
        let deleted = try XCTUnwrap(deletedID)
        networks.flushPendingWrites()

        XCTAssertNil(networks.profile(id: deleted))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("Networks/\(deleted)").path))
        XCTAssertEqual(networks.profiles.count, 1)
        assertEveryResultIsInItsOwnNetwork(networks)
    }

    /// Two requests at once — the iOS background task and the schedule, say —
    /// share one test rather than running two that race each other to the log.
    func testConcurrentProbeRequestsShareOneTest() async throws {
        let engine = ScriptedEngine(results: [successResult()])
        await engine.setRunDelay(nanoseconds: 100_000_000)
        let h = MonitorHarness(engine: engine)

        async let first = h.monitor.probeOnce()
        async let second = h.monitor.probeOnce()
        let (a, b) = await (first, second)

        let runs = await engine.runCount
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(h.networks.activeStore.results.count, 1)
    }

    /// At launch the first probe used to run before the router was known,
    /// creating a router-less duplicate of the real network.
    func testFirstProbeWaitsUntilTheRouterIsKnown() async throws {
        let engine = ScriptedEngine(results: [successResult()])
        let h = MonitorHarness(engine: engine, reportsInitialPath: false)
        h.monitor.start()
        defer { h.monitor.stop() }

        try await Task.sleep(nanoseconds: 100_000_000)
        let runsBeforeRouterKnown = await engine.runCount
        XCTAssertEqual(runsBeforeRouterKnown, 0, "must not identify a network without its router")

        h.path.apply(isSatisfied: true, interface: .wifi, gatewayIP: MonitorHarness.homeRouter)
        try await waitUntil("first probe") { await engine.runCount >= 1 }

        XCTAssertEqual(h.networks.profiles.count, 1)
        XCTAssertEqual(h.networks.activeProfile?.gatewayIP, MonitorHarness.homeRouter)
    }

    /// Back and forth between two networks, switching while tests are in
    /// flight. Every result must sit in the log of the router it was actually
    /// measured on. (Checking a result's stored network ID is not enough:
    /// a cross-filed result carries the wrong network's ID and sits in that
    /// network's folder, so the two agree while both are wrong.)
    func testRepeatedMidTestSwitchingNeverCrossFiles() async throws {
        let engine = ScriptedEngine(results: [successResult()])
        await engine.setRunDelay(nanoseconds: 40_000_000)
        let h = MonitorHarness(engine: engine)
        let path = h.path
        await engine.setCurrentRouter { await MainActor.run { path.gatewayIP } }

        h.monitor.start()
        defer { h.monitor.stop() }

        // One switch per test, each landing while that test is in flight.
        var lastProbe = 0
        for index in 0..<6 {
            try await waitUntil("test \(index + 1) in flight") {
                await engine.runCount > lastProbe && h.monitor.activity == .probing
            }
            lastProbe = await engine.runCount
            let router = index % 2 == 0 ? MonitorHarness.officeRouter : MonitorHarness.homeRouter
            h.path.apply(isSatisfied: true, interface: .wifi, gatewayIP: router)
        }
        try await waitUntil("a clean test on the final network") {
            !h.networks.activeStore.results.isEmpty && h.monitor.activity != .probing
        }

        XCTAssertEqual(h.networks.profiles.count, 2)
        XCTAssertGreaterThan(h.monitor.discardedProbeCount, 0)
        for profile in h.networks.profiles {
            let router = try XCTUnwrap(profile.gatewayIP)
            for result in h.networks.store(for: profile.id).results {
                XCTAssertEqual(result.endpointName, "measured-on:\(router)", "a measurement from another router was filed under \(router)")
                XCTAssertEqual(result.networkID, profile.id)
            }
        }
    }
}

@MainActor
final class NetworkLibraryTests: XCTestCase {

    private func makeLibrary(root: URL? = nil) -> (NetworkLibrary, URL) {
        let root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("routerwatch-tests-\(UUID().uuidString)", isDirectory: true)
        let library = NetworkLibrary(rootDirectory: root)
        library.load()
        return (library, root)
    }

    private let home = NetworkObservation(interface: .wifi, gatewayIP: "192.168.1.1", isp: .charter)
    private let office = NetworkObservation(interface: .wired, gatewayIP: "10.0.0.1", isp: .att)

    func testNetworksPersistIndependentlyAcrossRelaunch() throws {
        let (library, root) = makeLibrary()
        let homeProfile = library.resolve(home)
        library.store(for: homeProfile.id).append(successResult(), retentionDays: 0)
        library.store(for: homeProfile.id).append(outageResult(), retentionDays: 0)

        let officeProfile = library.resolve(office)
        library.store(for: officeProfile.id).append(successResult(), retentionDays: 0)
        library.rename(homeProfile.id, to: "Home Wi-Fi")
        library.flushPendingWrites()

        let (reloaded, _) = makeLibrary(root: root)
        XCTAssertEqual(reloaded.profiles.count, 2)
        XCTAssertEqual(reloaded.activeNetworkID, officeProfile.id)
        XCTAssertEqual(reloaded.profile(id: homeProfile.id)?.displayName, "Home Wi-Fi")
        XCTAssertEqual(reloaded.store(for: homeProfile.id).results.count, 2)
        XCTAssertEqual(reloaded.store(for: officeProfile.id).results.count, 1)
        XCTAssertEqual(reloaded.totalMeasurementCount, 3)
    }

    /// Repairs data from earlier builds: a duplicate created before the router
    /// was known is folded back into the one real network with that ISP.
    func testRouterlessDuplicateIsMergedIntoTheRealNetwork() throws {
        let (library, root) = makeLibrary()
        // Results carry their network's ID, as every probe records them.
        func result(_ base: ProbeResult, on id: String) -> ProbeResult {
            var result = base
            result.networkID = id
            return result
        }

        let orphan = library.resolve(NetworkObservation(interface: .wifi, gatewayIP: nil, isp: .charter))
        library.store(for: orphan.id).append(result(successResult(), on: orphan.id), retentionDays: 0)
        library.store(for: orphan.id).append(result(outageResult(), on: orphan.id), retentionDays: 0)

        let real = library.resolve(home)
        XCTAssertNotEqual(real.id, orphan.id, "precondition: the duplicate exists")
        library.store(for: real.id).append(result(successResult(), on: real.id), retentionDays: 0)
        library.flushPendingWrites()

        XCTAssertEqual(library.mergeRouterlessDuplicates(), 1)

        XCTAssertNil(library.profile(id: orphan.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Networks/\(orphan.id)").path))
        let results = library.store(for: real.id).results
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.networkID == real.id })
        XCTAssertEqual(library.mergeRouterlessDuplicates(), 0, "nothing left to merge")
    }

    /// With two real networks on the same ISP there is no telling which one
    /// the duplicate was, so it is left alone rather than guessed.
    func testAmbiguousDuplicateIsLeftAlone() {
        let (library, _) = makeLibrary()
        let orphan = library.resolve(NetworkObservation(interface: .wifi, gatewayIP: nil, isp: .charter))
        library.resolve(NetworkObservation(interface: .wifi, gatewayIP: "192.168.1.1", isp: .charter))
        library.resolve(NetworkObservation(interface: .wifi, gatewayIP: "192.168.0.1", isp: .charter))

        XCTAssertEqual(library.mergeRouterlessDuplicates(), 0)
        XCTAssertNotNil(library.profile(id: orphan.id))
    }

    func testDuplicateIsNeverMergedIntoADifferentProvider() {
        let (library, _) = makeLibrary()
        let orphan = library.resolve(NetworkObservation(interface: .wifi, gatewayIP: nil, isp: .charter))
        library.resolve(office)

        XCTAssertEqual(library.mergeRouterlessDuplicates(), 0)
        XCTAssertNotNil(library.profile(id: orphan.id))
    }

    func testReturningToAKnownNetworkReusesItsLog() {
        let (library, _) = makeLibrary()
        let first = library.resolve(home)
        library.resolve(office)
        let again = library.resolve(home)
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(library.profiles.count, 2)
    }

    func testBlankRenameRestoresAutomaticName() {
        let (library, _) = makeLibrary()
        let profile = library.resolve(home)
        library.rename(profile.id, to: "Home")
        XCTAssertEqual(library.profile(id: profile.id)?.displayName, "Home")
        library.rename(profile.id, to: "   ")
        XCTAssertEqual(library.profile(id: profile.id)?.displayName, "Charter Communications Inc · 192.168.1.1")
    }

    func testDeletingANetworkLeavesOthersIntact() {
        let (library, root) = makeLibrary()
        let homeProfile = library.resolve(home)
        library.store(for: homeProfile.id).append(successResult(), retentionDays: 0)
        let officeProfile = library.resolve(office)
        library.store(for: officeProfile.id).append(successResult(), retentionDays: 0)
        library.flushPendingWrites()

        library.delete(homeProfile.id)

        XCTAssertNil(library.profile(id: homeProfile.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Networks/\(homeProfile.id)").path))
        XCTAssertEqual(library.store(for: officeProfile.id).results.count, 1)
        XCTAssertEqual(library.activeNetworkID, officeProfile.id)
    }

    func testViewingTheActiveNetworkFollowsIt() {
        let (library, _) = makeLibrary()
        let homeProfile = library.resolve(home)
        let officeProfile = library.resolve(office)

        library.view(homeProfile.id)
        XCTAssertFalse(library.isViewingActiveNetwork)
        XCTAssertEqual(library.viewedProfile?.id, homeProfile.id)

        library.view(officeProfile.id)
        XCTAssertNil(library.viewedNetworkID, "choosing the current network means following it")
        XCTAssertTrue(library.isViewingActiveNetwork)
    }

    /// Results from before networks were tracked move into their own network
    /// and are never merged into a live one by guesswork.
    func testSingleLogIsMigratedIntoItsOwnNetwork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("routerwatch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyFile = root.appendingPathComponent("measurements.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([successResult(), outageResult()]).write(to: legacyFile)

        let (library, _) = makeLibrary(root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        let legacy = try XCTUnwrap(library.profile(id: NetworkProfile.legacyID))
        XCTAssertTrue(legacy.isLegacy)
        XCTAssertEqual(library.store(for: legacy.id).results.count, 2)

        let live = library.resolve(home)
        XCTAssertNotEqual(live.id, legacy.id)
    }

    /// An older build, run after a migration, recreates the single log. The
    /// next migration must add to the earlier results, not replace them.
    func testSecondMigrationMergesInsteadOfOverwriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("routerwatch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyFile = root.appendingPathComponent("measurements.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let first = successResult()
        try encoder.encode([first]).write(to: legacyFile)
        let (library, _) = makeLibrary(root: root)
        XCTAssertEqual(library.store(for: NetworkProfile.legacyID).results.count, 1)
        library.flushPendingWrites()

        // The old build writes its own log again, including the row it already had.
        let second = outageResult()
        try encoder.encode([first, second]).write(to: legacyFile)
        let (reopened, _) = makeLibrary(root: root)

        let results = reopened.store(for: NetworkProfile.legacyID).results
        XCTAssertEqual(results.count, 2, "existing rows kept, duplicates not re-added")
        XCTAssertEqual(results.map(\.id), [first.id, second.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
    }
}

final class NetworkMatcherTests: XCTestCase {

    private func profile(_ observation: NetworkObservation, lastSeen: TimeInterval = 0) -> NetworkProfile {
        var profile = NetworkProfile(observation: observation, now: Date(timeIntervalSince1970: 0))
        profile.lastSeen = Date(timeIntervalSince1970: lastSeen)
        return profile
    }

    func testSameRouterAndProviderMatches() {
        let known = profile(.init(interface: .wifi, gatewayIP: "192.168.1.1", isp: .charter))
        let match = NetworkMatcher.bestMatch(for: .init(interface: .wifi, gatewayIP: "192.168.1.1", isp: .charter), in: [known])
        XCTAssertEqual(match?.id, known.id)
    }

    /// Wi-Fi and Ethernet on the same router are one network.
    func testInterfaceTypeIsNotPartOfIdentity() {
        let known = profile(.init(interface: .wifi, gatewayIP: "192.168.1.1", isp: .charter))
        let match = NetworkMatcher.bestMatch(for: .init(interface: .wired, gatewayIP: "192.168.1.1", isp: .charter), in: [known])
        XCTAssertEqual(match?.id, known.id)
    }

    /// Two homes with the ubiquitous 192.168.1.1 router but different ISPs.
    func testSameRouterAddressWithDifferentProviderIsANewNetwork() {
        let known = profile(.init(interface: .wifi, gatewayIP: "192.168.1.1", isp: .charter))
        XCTAssertNil(NetworkMatcher.bestMatch(for: .init(interface: .wifi, gatewayIP: "192.168.1.1", isp: .att), in: [known]))
    }

    func testDifferentRouterWithSameProviderIsANewNetwork() {
        let known = profile(.init(interface: .wifi, gatewayIP: "192.168.1.1", isp: .charter))
        XCTAssertNil(NetworkMatcher.bestMatch(for: .init(interface: .wifi, gatewayIP: "192.168.0.1", isp: .charter), in: [known]))
    }

    func testUnknownProviderMatchesMostRecentNetworkOnThatRouter() {
        let older = profile(.init(interface: .wifi, gatewayIP: "192.168.1.1", isp: .att), lastSeen: 100)
        let newer = profile(.init(interface: .wifi, gatewayIP: "192.168.1.1", isp: .charter), lastSeen: 200)
        let match = NetworkMatcher.bestMatch(for: .init(interface: .wifi, gatewayIP: "192.168.1.1", isp: nil), in: [older, newer])
        XCTAssertEqual(match?.id, newer.id)
    }

    /// First seen during an outage, provider learned later: same network.
    func testNetworkFirstSeenOfflineIsClaimedOnceProviderIsKnown() {
        let unidentified = profile(.init(interface: .wifi, gatewayIP: "192.168.1.1", isp: nil))
        let match = NetworkMatcher.bestMatch(for: .init(interface: .wifi, gatewayIP: "192.168.1.1", isp: .charter), in: [unidentified])
        XCTAssertEqual(match?.id, unidentified.id)
    }

    func testCellularMatchesOnCarrierAndIgnoresGateway() {
        let known = profile(.init(interface: .cellular, gatewayIP: nil, isp: .tmobile))
        let match = NetworkMatcher.bestMatch(for: .init(interface: .cellular, gatewayIP: "fe80::1", isp: .tmobile), in: [known])
        XCTAssertEqual(match?.id, known.id)
        XCTAssertNil(NetworkMatcher.bestMatch(for: .init(interface: .wifi, gatewayIP: nil, isp: .tmobile), in: [known]))
    }

    func testLegacyNetworkIsNeverMatched() {
        let legacy = NetworkProfile.legacy(firstSeen: Date(), lastSeen: Date())
        XCTAssertNil(NetworkMatcher.bestMatch(for: .init(interface: .none, gatewayIP: nil, isp: nil), in: [legacy]))
    }
}

@MainActor
final class NetworkPathMonitorTests: XCTestCase {

    func testSwitchingRoutersWhileOnlineAnnouncesANetworkChange() {
        let path = NetworkPathMonitor()
        var changes = 0
        var availability: [Bool] = []
        path.onNetworkChange = { changes += 1 }
        path.onAvailabilityChange = { availability.append($0) }

        path.apply(isSatisfied: true, interface: .wifi, gatewayIP: "192.168.1.1")
        XCTAssertEqual(changes, 0, "learning the first router is not a switch")

        path.apply(isSatisfied: true, interface: .wifi, gatewayIP: "10.0.0.1")
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(availability.isEmpty)
    }

    func testRouterChangesAreCountedIncludingAcrossOfflineGaps() {
        let path = NetworkPathMonitor()
        path.apply(isSatisfied: true, interface: .wifi, gatewayIP: "192.168.1.1")
        XCTAssertEqual(path.routerChangeCount, 0, "the first report is not a change")

        path.apply(isSatisfied: false, interface: .wifi)
        path.apply(isSatisfied: true, interface: .wifi, gatewayIP: "192.168.1.1")
        XCTAssertEqual(path.routerChangeCount, 0, "rejoining the same router is not a change")

        path.apply(isSatisfied: false, interface: .wifi)
        path.apply(isSatisfied: true, interface: .wifi, gatewayIP: "10.0.0.1")
        XCTAssertEqual(path.routerChangeCount, 1, "a different router after an offline gap is a change")

        path.apply(isSatisfied: false, interface: .wifi)
        path.apply(isSatisfied: true, interface: .cellular, gatewayIP: nil)
        XCTAssertEqual(path.routerChangeCount, 2, "Wi-Fi to cellular is a change even with no gateway to compare")
    }

    func testRouterIsRememberedWhileOffline() {
        let path = NetworkPathMonitor()
        var changes = 0
        path.onNetworkChange = { changes += 1 }
        path.apply(isSatisfied: true, interface: .wifi, gatewayIP: "192.168.1.1")
        path.apply(isSatisfied: false, interface: .wifi)
        XCTAssertEqual(path.gatewayIP, "192.168.1.1")
        XCTAssertEqual(changes, 0, "going offline is an availability change, not a network change")
    }
}

final class NetworkIdentifierTests: XCTestCase {

    func testParsesProviderAndDiscardsPreciseLocation() throws {
        let json = """
        {"hostname":"speed.cloudflare.com","clientIp":"67.8.88.85","asn":33363,
         "asOrganization":"Charter Communications Inc","country":"US","city":"Deltona",
         "region":"Florida","postalCode":"32725","latitude":"28.90054","longitude":"-81.26367"}
        """
        let info = try XCTUnwrap(NetworkIdentifier.parse(Data(json.utf8)))
        XCTAssertEqual(info, .charter)

        let encoded = try String(decoding: JSONEncoder().encode(info), as: UTF8.self)
        XCTAssertFalse(encoded.contains("32725"))
        XCTAssertFalse(encoded.contains("28.9"))
    }

    func testMissingProviderIsNotAnIdentification() {
        XCTAssertNil(NetworkIdentifier.parse(Data(#"{"clientIp":"1.2.3.4"}"#.utf8)))
        XCTAssertNil(NetworkIdentifier.parse(Data("not json".utf8)))
    }
}

@MainActor
final class OutageStartTests: XCTestCase {

    func testOutageStartIsTheBeginningOfTheTrailingStreak() {
        let store = MeasurementStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("routerwatch-tests-\(UUID().uuidString).json")
        )
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func add(_ offset: TimeInterval, _ kind: ErrorKind?) {
            let timestamp = t0.addingTimeInterval(offset)
            if let kind {
                store.append(.failure(timestamp: timestamp, endpointName: "T", interface: .wifi, kind: kind, detail: ""), retentionDays: 0)
            } else {
                store.append(ProbeResult(timestamp: timestamp, endpointName: "T", interface: .wifi, bytesDownloaded: 1, bytesUploaded: 0, duration: 1), retentionDays: 0)
            }
        }

        XCTAssertNil(store.currentOutageStart())
        add(0, .timeout)
        add(60, nil)
        XCTAssertNil(store.currentOutageStart(), "a success ends the streak")

        add(120, .dnsFailure)
        add(180, .cannotConnect)
        add(240, .timeout)
        XCTAssertEqual(store.currentOutageStart(), t0.addingTimeInterval(120))

        add(300, .lowThroughput)
        XCTAssertNil(store.currentOutageStart(), "a slow-but-working result ends an outage")
    }

    func testDurationFormatting() {
        XCTAssertEqual(Format.duration(45), "45s")
        XCTAssertEqual(Format.duration(725), "12m 5s")
        XCTAssertEqual(Format.duration(3 * 3600 + 20 * 60 + 9), "3h 20m")
    }
}

// MARK: - Chart rendering

@MainActor
final class ThroughputChartRenderingTests: XCTestCase {

    /// A day of probes every 15 minutes, as the chart normally shows.
    private func day(of count: Int = 96) -> [ProbeResult] {
        let start = Date().addingTimeInterval(-86_400)
        return (0..<count).map { index in
            var result = successResult()
            result.timestamp = start.addingTimeInterval(Double(index) * 900)
            result.downloadMbps = 60 + Double(index % 7) * 4
            return result
        }
    }

    /// Renders the chart off-screen. Charts reports mark-sizing problems on the
    /// console while rendering; the build output is checked for them.
    func testThroughputChartRenders() throws {
        let view = ThroughputChartView(results: day(), thresholdMbps: 10, showsUpload: true)
            .frame(width: 700, height: 240)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "chart failed to render")
        XCTAssertEqual(image.width, 700)
    }

    private func timestamps(every seconds: TimeInterval, count: Int, from start: Date = Date(timeIntervalSince1970: 0)) -> [Date] {
        (0..<count).map { start.addingTimeInterval(Double($0) * seconds) }
    }

    /// The everyday case: a day of 15-minute probes gets bars a few points wide.
    func testBarsForADayOfFifteenMinuteProbes() {
        let width = ThroughputChartView.barWidth(for: timestamps(every: 900, count: 96), plotWidth: 660)
        // 660 pt × (one 900 s gap ÷ 85,500 s span) × 0.7
        XCTAssertEqual(width, 4.86, accuracy: 0.01)
    }

    /// Very frequent probes never shrink below something visible.
    func testDenseProbesAreClampedToAVisibleWidth() {
        XCTAssertEqual(ThroughputChartView.barWidth(for: timestamps(every: 60, count: 1_440), plotWidth: 660), 1.5)
    }

    func testSingleProbeGetsTheWidestBar() {
        XCTAssertEqual(ThroughputChartView.barWidth(for: [Date()], plotWidth: 660), 14)
        XCTAssertEqual(ThroughputChartView.barWidth(for: [], plotWidth: 660), 14)
    }

    /// A long overnight gap is one gap among many; it must not make every bar
    /// a sliver.
    func testOneLongGapDoesNotShrinkEveryBar() {
        let evening = timestamps(every: 900, count: 16)
        let morning = timestamps(every: 900, count: 16, from: evening.last!.addingTimeInterval(8 * 3600))
        let width = ThroughputChartView.barWidth(for: evening + morning, plotWidth: 660)
        let span = (evening + morning).last!.timeIntervalSince(evening.first!)
        XCTAssertEqual(width, 660 * CGFloat(900 / span) * 0.7, accuracy: 0.01)
        XCTAssertGreaterThan(width, 5)
    }
}

// MARK: - App Intents

@MainActor
final class AppIntentTests: XCTestCase {

    private var environment: AppEnvironment!
    private var engine: ScriptedEngine!

    private func makeEnvironment(results: [ProbeResult]) -> AppEnvironment {
        engine = ScriptedEngine(results: results)
        let environment = AppEnvironment(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("routerwatch-tests-\(UUID().uuidString)", isDirectory: true),
            defaults: UserDefaults(suiteName: "routerwatch-tests-\(UUID().uuidString)")!,
            engine: engine,
            identifier: FakeIdentifier([MonitorHarness.homeRouter: .charter, MonitorHarness.officeRouter: .att]),
            timing: MonitorHarness.fastTiming
        )
        environment.pathMonitor.apply(isSatisfied: true, interface: .wifi, gatewayIP: MonitorHarness.homeRouter)
        IntentContext.setEnvironment(environment)
        self.environment = environment
        return environment
    }

    override func tearDown() {
        IntentContext.setEnvironment(nil)
        environment = nil
        engine = nil
        super.tearDown()
    }

    /// "Hey Siri, run a speed test": measures, hands the download speed back
    /// for later shortcut steps, and records it in the network's log.
    func testRunSpeedTestMeasuresAndRecords() async throws {
        let environment = makeEnvironment(results: [successResult()])

        let output = try await RunSpeedTestIntent().perform()

        XCTAssertEqual(output.value, 90)
        XCTAssertEqual(environment.networks.activeStore.results.count, 1)
        XCTAssertEqual(environment.networks.activeProfile?.isp?.asn, ISPInfo.charter.asn)
    }

    /// A failed test is an answer, not an error: a shortcut that logs outages
    /// must keep running rather than abort.
    func testRunSpeedTestReportsAnOutageAsZero() async throws {
        let environment = makeEnvironment(results: [outageResult(.dnsFailure)])

        let output = try await RunSpeedTestIntent().perform()

        XCTAssertEqual(output.value, 0)
        XCTAssertEqual(environment.networks.activeStore.results.count, 1, "the outage is still recorded")
    }

    /// Status comes from the log, so it works in a launch where the monitor
    /// never ran — which is exactly how Shortcuts starts the app.
    func testConnectionStatusWithoutTheMonitorRunning() async throws {
        let environment = makeEnvironment(results: [successResult()])
        _ = try await RunSpeedTestIntent().perform()
        XCTAssertEqual(environment.monitor.activity, .stopped, "precondition: no monitoring loop in this launch")

        let output = try await GetConnectionStatusIntent().perform()

        XCTAssertEqual(output.value, "Connection OK")
    }

    func testConnectionStatusReportsAnOutage() async throws {
        _ = makeEnvironment(results: [outageResult(.cannotConnect)])
        _ = try await RunSpeedTestIntent().perform()

        let output = try await GetConnectionStatusIntent().perform()

        XCTAssertEqual(output.value, "Connection Down")
    }

    func testConnectionStatusBeforeAnyTest() async throws {
        _ = makeEnvironment(results: [successResult()])

        let output = try await GetConnectionStatusIntent().perform()

        XCTAssertEqual(output.value, "No Data Yet")
    }

    /// Availability comes back as a percentage, the figure worth quoting at
    /// an ISP, with the rest in the spoken reply.
    func testStatisticsForTheCurrentNetwork() async throws {
        let environment = makeEnvironment(results: [successResult(), outageResult(), successResult()])
        for _ in 0..<4 {
            _ = try await RunSpeedTestIntent().perform()
        }

        let intent = GetNetworkStatisticsIntent()
        intent.range = .hour24
        let output = try await intent.perform()

        let store = environment.networks.activeStore
        XCTAssertEqual(store.results.count, 4)
        // One of the four tests was an outage.
        XCTAssertEqual(try XCTUnwrap(output.value), 75, accuracy: 0.001)
    }

    /// A shortcut can ask about a network the device is not on right now.
    func testStatisticsForAnotherNetwork() async throws {
        let environment = makeEnvironment(results: [successResult()])
        _ = try await RunSpeedTestIntent().perform()
        let home = try XCTUnwrap(environment.networks.activeProfile)

        // Move to the office network and record a failure there.
        await engine.setResults([outageResult()])
        environment.pathMonitor.apply(isSatisfied: true, interface: .wifi, gatewayIP: MonitorHarness.officeRouter)
        _ = try await RunSpeedTestIntent().perform()
        let office = try XCTUnwrap(environment.networks.activeProfile)
        XCTAssertNotEqual(home.id, office.id)

        let intent = GetNetworkStatisticsIntent()
        intent.range = .hour24
        intent.network = NetworkEntity(profile: home, measurementCount: 1)
        let output = try await intent.perform()

        XCTAssertEqual(try XCTUnwrap(output.value), 100, accuracy: 0.001, "the home network was healthy, the office one was not")
    }

    func testStatisticsWithNothingRecorded() async throws {
        _ = makeEnvironment(results: [successResult()])
        let intent = GetNetworkStatisticsIntent()
        intent.range = .hour24

        let output = try await intent.perform()

        XCTAssertEqual(output.value, 0)
    }

    func testSetMonitoringPausesAndResumes() async throws {
        let environment = makeEnvironment(results: [successResult()])

        let pause = SetMonitoringIntent()
        pause.enabled = false
        _ = try await pause.perform()
        XCTAssertFalse(environment.settings.isMonitoringEnabled)
        XCTAssertEqual(environment.monitor.activity, .stopped)
        XCTAssertEqual(environment.monitor.health, .paused)

        let resume = SetMonitoringIntent()
        resume.enabled = true
        _ = try await resume.perform()
        XCTAssertTrue(environment.settings.isMonitoringEnabled)
        XCTAssertNotEqual(environment.monitor.activity, .stopped)
        environment.monitor.stop()
    }

    /// The Shortcuts network picker lists the user's networks by name.
    func testNetworkPickerListsKnownNetworks() async throws {
        let environment = makeEnvironment(results: [successResult()])
        _ = try await RunSpeedTestIntent().perform()
        environment.pathMonitor.apply(isSatisfied: true, interface: .wifi, gatewayIP: MonitorHarness.officeRouter)
        _ = try await RunSpeedTestIntent().perform()
        environment.networks.rename(try XCTUnwrap(environment.networks.activeNetworkID), to: "Office")

        let suggested = try await NetworkEntityQuery().suggestedEntities()
        XCTAssertEqual(suggested.count, 2)
        XCTAssertTrue(suggested.contains { $0.name == "Office" })

        let office = try XCTUnwrap(suggested.first { $0.name == "Office" })
        let looked = try await NetworkEntityQuery().entities(for: [office.id])
        XCTAssertEqual(looked.first?.name, "Office")
        XCTAssertEqual(looked.first?.routerAddress, MonitorHarness.officeRouter)
    }
}
