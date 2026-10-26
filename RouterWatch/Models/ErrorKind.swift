//
//  ErrorKind.swift
//  RouterWatch
//

import Foundation

/// The taxonomy the log and the bar chart group failures by.
///
/// Every failed probe is reduced to exactly one of these so that "what is
/// actually wrong with this connection" is answerable at a glance: DNS
/// trouble, a router that cannot reach the WAN, and a link that is merely
/// slow are three very different conversations with an ISP.
enum ErrorKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The OS reports no usable network interface at all (Wi-Fi off, cable out).
    case noNetworkPath
    /// The host name could not be resolved — usually the router's DNS forwarder.
    case dnsFailure
    /// TCP connection refused or unreachable: the WAN side is likely down.
    case cannotConnect
    /// The connection dropped mid-transfer.
    case connectionLost
    /// The request exceeded its deadline without completing.
    case timeout
    /// TLS handshake or certificate validation failed (captive portal, MITM).
    case tlsFailure
    /// The endpoint answered, but with a non-2xx status.
    case httpError
    /// The test server is throttling this network (HTTP 429). Not a fault in
    /// the connection — usually a sign the schedule is too aggressive.
    case rateLimited
    /// The transfer succeeded but came in under the configured floor.
    case lowThroughput
    /// Round-trip time exceeded the configured ceiling.
    case highLatency
    /// The probe was cancelled (app quit, monitoring paused mid-run).
    case cancelled
    /// Anything that did not match a more specific bucket.
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noNetworkPath: return "No Network"
        case .dnsFailure: return "DNS Failure"
        case .cannotConnect: return "Cannot Connect"
        case .connectionLost: return "Connection Lost"
        case .timeout: return "Timeout"
        case .tlsFailure: return "TLS Failure"
        case .httpError: return "HTTP Error"
        case .rateLimited: return "Rate Limited"
        case .lowThroughput: return "Low Throughput"
        case .highLatency: return "High Latency"
        case .cancelled: return "Cancelled"
        case .unknown: return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .noNetworkPath: return "wifi.slash"
        case .dnsFailure: return "questionmark.circle"
        case .cannotConnect: return "bolt.horizontal.circle"
        case .connectionLost: return "cable.connector.slash"
        case .timeout: return "clock.badge.exclamationmark"
        case .tlsFailure: return "lock.trianglebadge.exclamationmark"
        case .httpError: return "exclamationmark.server"
        case .rateLimited: return "hand.raised"
        case .lowThroughput: return "tortoise"
        case .highLatency: return "hourglass"
        case .cancelled: return "xmark.circle"
        case .unknown: return "questionmark.diamond"
        }
    }

    var explanation: String {
        switch self {
        case .noNetworkPath:
            return "This device had no active network interface. The problem is between the device and the router, not on the internet side."
        case .dnsFailure:
            return "The test host name could not be resolved. Most often the router's DNS forwarder or the ISP's resolver."
        case .cannotConnect:
            return "The connection was refused or the host was unreachable. Typically the router has no working WAN link."
        case .connectionLost:
            return "The connection dropped part way through the transfer — a sign of an unstable line or a rebooting router."
        case .timeout:
            return "The endpoint did not respond in time. Congestion, a saturated uplink, or an outage upstream."
        case .tlsFailure:
            return "The secure handshake failed. Common on captive portals and on networks doing TLS interception."
        case .httpError:
            return "The test endpoint answered with an error status. The internet connection worked — the problem is on the server's side, not your router's."
        case .rateLimited:
            return "The test server is throttling this network because it received too many tests. Your connection is fine; use a longer interval or a smaller download size."
        case .lowThroughput:
            return "The transfer completed but below your configured floor. The line is up but not delivering its rated speed."
        case .highLatency:
            return "Round-trip time exceeded your configured ceiling. Bufferbloat or an overloaded uplink."
        case .cancelled:
            return "The probe was stopped before it finished, usually because monitoring was paused or the app quit."
        case .unknown:
            return "The failure did not match a known category. See the detail text on the log entry."
        }
    }

    /// `true` when the connection itself failed, as opposed to a degraded link
    /// or a server that answered but refused. Uptime accounting only counts
    /// hard failures as outages — an HTTP error response proves the internet
    /// path worked, so it must not be charged against the router.
    var isHardFailure: Bool {
        switch self {
        case .lowThroughput, .highLatency, .cancelled, .httpError, .rateLimited: return false
        default: return true
        }
    }

    /// Stable ordering for charts so bars do not jump around between refreshes.
    var sortRank: Int {
        ErrorKind.allCases.firstIndex(of: self) ?? 0
    }
}

// MARK: - Classification

extension ErrorKind {
    /// Reduces any thrown error to a chart bucket plus a human-readable detail line.
    static func classify(_ error: Error) -> (kind: ErrorKind, detail: String) {
        if let probeError = error as? ProbeError {
            return (probeError.kind, probeError.detail)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let kind: ErrorKind
            switch URLError.Code(rawValue: nsError.code) {
            case .notConnectedToInternet:
                kind = .noNetworkPath
            case .cannotFindHost, .dnsLookupFailed:
                kind = .dnsFailure
            case .cannotConnectToHost, .resourceUnavailable:
                kind = .cannotConnect
            case .networkConnectionLost:
                kind = .connectionLost
            case .timedOut:
                kind = .timeout
            case .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired,
                 .appTransportSecurityRequiresSecureConnection:
                kind = .tlsFailure
            case .badServerResponse, .unsupportedURL, .badURL:
                kind = .httpError
            case .cancelled:
                kind = .cancelled
            default:
                kind = .unknown
            }
            return (kind, nsError.localizedDescription)
        }

        if error is CancellationError {
            return (.cancelled, "The probe was cancelled.")
        }

        return (.unknown, nsError.localizedDescription)
    }
}

// MARK: - Probe errors raised by RouterWatch itself

enum ProbeError: Error {
    case noNetworkPath
    case invalidEndpoint(String)
    case httpStatus(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case emptyResponse
    case shortResponse(expected: Int, received: Int)
    case belowThreshold(actual: Double, threshold: Double)
    case latencyAboveThreshold(actual: Double, threshold: Double)

    var kind: ErrorKind {
        switch self {
        case .noNetworkPath: return .noNetworkPath
        case .invalidEndpoint: return .unknown
        case .httpStatus: return .httpError
        case .rateLimited: return .rateLimited
        case .emptyResponse: return .httpError
        case .shortResponse: return .httpError
        case .belowThreshold: return .lowThroughput
        case .latencyAboveThreshold: return .highLatency
        }
    }

    var detail: String {
        switch self {
        case .noNetworkPath:
            return "No active network interface."
        case .invalidEndpoint(let urlString):
            return "Could not build a valid URL from \"\(urlString)\"."
        case .httpStatus(let code):
            return "Endpoint responded with HTTP \(code)."
        case .rateLimited(let retryAfter):
            guard let retryAfter, retryAfter > 0 else {
                return "Test server is rate limiting this network (HTTP 429)."
            }
            let minutes = Int((retryAfter / 60).rounded(.up))
            return "Test server is rate limiting this network (HTTP 429) and asked for a \(minutes)-minute pause."
        case .emptyResponse:
            return "Endpoint returned no data."
        case .shortResponse(let expected, let received):
            let receivedText = ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)
            let expectedText = ByteCountFormatter.string(fromByteCount: Int64(expected), countStyle: .file)
            return "Endpoint sent only \(receivedText) of the \(expectedText) requested, which is a refusal rather than a measurable transfer."
        case .belowThreshold(let actual, let threshold):
            return String(format: "Download measured %.1f Mbps, below the %.0f Mbps floor.", actual, threshold)
        case .latencyAboveThreshold(let actual, let threshold):
            return String(format: "Latency measured %.0f ms, above the %.0f ms ceiling.", actual, threshold)
        }
    }
}

extension ProbeError {
    /// The server was reachable and answered, but refused or returned nothing
    /// usable. These are worth retrying against another test point, because
    /// the connection under test is evidently working.
    var isServerSide: Bool {
        switch self {
        case .httpStatus, .rateLimited, .emptyResponse, .shortResponse: return true
        default: return false
        }
    }

    /// Maps a non-2xx response to the right error, reading `Retry-After` when
    /// the server supplied one in seconds.
    static func forStatus(_ status: Int, retryAfterHeader: String?) -> ProbeError {
        if status == 429 {
            let seconds = retryAfterHeader
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: seconds)
        }
        return .httpStatus(status)
    }
}

extension ProbeError: LocalizedError {
    var errorDescription: String? { detail }
}
