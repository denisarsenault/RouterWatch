//
//  TransferMeter.swift
//  RouterWatch
//

import Foundation

/// Which direction a meter is measuring. Uploads are timed differently from
/// downloads, so the meter has to know.
enum TransferDirection: Sendable {
    case download
    case upload
}

/// The raw numbers one transfer produced.
struct TransferSummary: Sendable {
    var totalBytes: Int
    /// Bytes that arrived after the warm-up window closed.
    var measuredBytes: Int
    var measuredSeconds: TimeInterval
    var totalSeconds: TimeInterval
    var statusCode: Int?
    var retryAfterHeader: String? = nil

    /// Throughput in megabits per second, using the post-warm-up window when
    /// one exists and the whole transfer otherwise.
    ///
    /// Megabits here are 1,000,000 bits, which is what ISPs quote — not 2^20.
    var megabitsPerSecond: Double {
        let usingWarmWindow = measuredBytes > 0 && measuredSeconds > 0.01
        let bytes = usingWarmWindow ? measuredBytes : totalBytes
        let seconds = usingWarmWindow ? measuredSeconds : totalSeconds
        guard seconds > 0.001, bytes > 0 else { return 0 }
        return (Double(bytes) * 8.0) / seconds / 1_000_000.0
    }
}

/// Times a single HTTP transfer at the delegate level.
///
/// `URLSession.bytes(for:)` would be tidier, but iterating an `AsyncBytes`
/// sequence one byte at a time caps out well below a fast line and would make
/// the app under-report throughput on exactly the connections worth testing.
/// The data-delegate callbacks hand over whole buffers instead, so the clock
/// measures the network rather than Swift's iteration overhead.
///
/// One instance measures one transfer; the session is invalidated afterwards.
final class TransferMeter: NSObject, @unchecked Sendable {
    private var direction: TransferDirection = .download

    /// Bytes arriving in this opening window are ignored. TCP slow start and
    /// the TLS handshake would otherwise drag the average down on short tests.
    private let warmup: TimeInterval

    private let lock = NSLock()
    private var continuation: CheckedContinuation<TransferSummary, Error>?
    private var startedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var firstDataAt: CFAbsoluteTime?
    private var measureStartAt: CFAbsoluteTime?
    private var lastDataAt: CFAbsoluteTime?
    private var totalBytes = 0
    private var measuredBytes = 0
    private var statusCode: Int?
    private var retryAfterHeader: String?

    init(warmup: TimeInterval = 0.3) {
        self.warmup = warmup
    }

    // MARK: - Public measurement API

    func measureDownload(url: URL, timeout: TimeInterval) async throws -> TransferSummary {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        direction = .download
        return try await perform(timeout: timeout) { session in
            session.dataTask(with: request)
        }
    }

    func measureUpload(url: URL, payload: Data, timeout: TimeInterval) async throws -> TransferSummary {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        direction = .upload
        return try await perform(timeout: timeout) { session in
            session.uploadTask(with: request, from: payload)
        }
    }

    // MARK: - Session plumbing

    private func perform(
        timeout: TimeInterval,
        _ makeTask: (URLSession) -> URLSessionTask
    ) async throws -> TransferSummary {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // Without this a probe run while the link is down parks indefinitely
        // instead of surfacing the outage we are trying to record.
        configuration.waitsForConnectivity = false

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.mybrightzone.routerwatch.transfer-meter"

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        startedAt = CFAbsoluteTimeGetCurrent()
        let task = makeTask(session)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TransferSummary, Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Records a chunk of transferred bytes against the warm-up window.
    ///
    /// The chunk that first crosses the warm-up boundary only starts the clock;
    /// its bytes are not counted, because they were in flight before the
    /// measurement window opened and would inflate the result.
    private func record(_ count: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }

        totalBytes += count
        if firstDataAt == nil { firstDataAt = now }

        if let first = firstDataAt, now - first >= warmup {
            if measureStartAt == nil {
                measureStartAt = now
            } else {
                measuredBytes += count
            }
        }
        lastDataAt = now
    }

    private func finish(error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil

        let now = CFAbsoluteTimeGetCurrent()
        var measured: TimeInterval
        var measuredForSummary = measuredBytes
        if let measureStartAt, let lastDataAt {
            measured = max(0, lastDataAt - measureStartAt)
        } else {
            measured = 0
        }

        // Uploads are timed from the first byte handed over until the server
        // finishes responding.
        //
        // `didSendBodyData` reports bytes written into the kernel's socket
        // buffer, not bytes the server received. On a fast machine the first
        // several megabytes are "sent" almost instantly, which made a 5 MB
        // upload on a 23 Mbps link measure as over 100 Mbps. Waiting for the
        // response means the whole payload really did cross the wire.
        if direction == .upload {
            if let firstDataAt {
                measured = max(0, now - firstDataAt)
                measuredForSummary = totalBytes
            } else {
                measured = 0
                measuredForSummary = 0
            }
        }
        let total: TimeInterval
        if let firstDataAt, let lastDataAt {
            total = max(0, lastDataAt - firstDataAt)
        } else {
            total = max(0, now - startedAt)
        }

        let summary = TransferSummary(
            totalBytes: totalBytes,
            measuredBytes: measuredForSummary,
            measuredSeconds: measured,
            totalSeconds: total,
            statusCode: statusCode,
            retryAfterHeader: retryAfterHeader
        )
        lock.unlock()

        guard let pending else { return }
        if let error {
            pending.resume(throwing: error)
        } else {
            pending.resume(returning: summary)
        }
    }
}

// MARK: - URLSession delegates

extension TransferMeter: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        lock.lock()
        statusCode = http?.statusCode
        retryAfterHeader = http?.value(forHTTPHeaderField: "Retry-After")
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // An upload's byte count is what was sent; the server's reply is not
        // part of the payload and must not inflate it.
        guard direction == .download else { return }
        record(data.count)
    }
}

extension TransferMeter: URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        record(Int(bytesSent))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error: error)
    }
}

// MARK: - Payload generation

enum UploadPayload {
    /// Builds an incompressible-enough body of the requested size.
    ///
    /// A block of random bytes is repeated rather than generating the whole
    /// payload randomly: filling 50 MB one byte at a time costs more CPU than
    /// the transfer itself, which would skew the very measurement being taken.
    static func make(byteCount: Int) -> Data {
        let blockSize = 64 * 1024
        var block = Data(count: blockSize)
        block.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var generator = SystemRandomNumberGenerator()
            for index in 0..<blockSize {
                base[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
            }
        }

        var payload = Data(capacity: byteCount)
        while payload.count + blockSize <= byteCount {
            payload.append(block)
        }
        let remainder = byteCount - payload.count
        if remainder > 0 {
            payload.append(block.prefix(remainder))
        }
        return payload
    }
}
