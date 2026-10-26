//
//  TestEndpoint.swift
//  RouterWatch
//

import Foundation

/// A measurement target that lives outside the local WAN.
///
/// Everything here is deliberately reachable over plain HTTPS with no API key,
/// so the app needs no account, no server of its own, and no ATS exceptions.
struct TestEndpoint: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    /// May contain the `{bytes}` placeholder; endpoints with a fixed payload
    /// size simply omit it.
    var downloadURLTemplate: String
    var uploadURLString: String?
    var latencyURLString: String?
    /// Fixed payload endpoints report how large their file is so throughput
    /// maths stay honest even though the request size is not adjustable.
    var fixedDownloadBytes: Int?
    var notes: String

    var supportsUpload: Bool { uploadURLString != nil }
    var supportsAdjustableDownloadSize: Bool { downloadURLTemplate.contains("{bytes}") }

    func downloadURL(bytes: Int) -> URL? {
        let string = downloadURLTemplate.replacingOccurrences(of: "{bytes}", with: String(bytes))
        return URL(string: string)
    }

    var uploadURL: URL? {
        uploadURLString.flatMap(URL.init(string:))
    }

    /// Fixed-size endpoints have no cheap URL to time, so latency is measured
    /// with `HEAD` requests instead — otherwise every latency sample would
    /// download the whole test file.
    var latencyUsesHEAD: Bool {
        latencyURLString == nil && !supportsAdjustableDownloadSize
    }

    /// Falls back to a zero-byte download when the endpoint has no dedicated
    /// latency path — the request still measures a full round trip.
    func latencyURL() -> URL? {
        if let latencyURLString, let url = URL(string: latencyURLString) {
            return url
        }
        return downloadURL(bytes: 0)
    }
}

extension TestEndpoint {
    static let cloudflare = TestEndpoint(
        id: "cloudflare",
        name: "Cloudflare Speed Test",
        downloadURLTemplate: "https://speed.cloudflare.com/__down?bytes={bytes}",
        uploadURLString: "https://speed.cloudflare.com/__up",
        latencyURLString: "https://speed.cloudflare.com/__down?bytes=0",
        fixedDownloadBytes: nil,
        notes: "Anycast edge, adjustable payload, supports upload measurement. The default."
    )

    static let cachefly = TestEndpoint(
        id: "cachefly",
        name: "CacheFly (10 MB)",
        downloadURLTemplate: "https://cachefly.cachefly.net/10mb.test",
        uploadURLString: nil,
        latencyURLString: nil,
        fixedDownloadBytes: 10_000_000,
        notes: "Fixed 10 MB file on a global CDN. Download and latency only."
    )

    /// Selected when the user supplies their own URL in Settings.
    static let customIdentifier = "custom"

    static func custom(downloadURLString: String) -> TestEndpoint {
        TestEndpoint(
            id: customIdentifier,
            name: "Custom Endpoint",
            downloadURLTemplate: downloadURLString,
            uploadURLString: nil,
            latencyURLString: nil,
            fixedDownloadBytes: nil,
            notes: "Your own HTTPS URL. Download and latency only."
        )
    }

    static let presets: [TestEndpoint] = [.cloudflare, .cachefly]
}
