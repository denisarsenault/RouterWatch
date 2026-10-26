//
//  NetworkIdentifier.swift
//  RouterWatch
//

import Foundation

/// What the monitor needs to put a name to a network. A seam for tests.
protocol NetworkIdentifying: Sendable {
    func ispInfo(gatewayIP: String?, interface: InterfaceKind) async -> ISPInfo?
}

/// Looks up which ISP the current network uses.
///
/// Asks Cloudflare's speed-test metadata endpoint, the same service the default
/// speed test already talks to, so no additional third party learns anything.
/// Only the ISP, public IP, and city-level location are kept; the coordinates
/// and postal code the endpoint also returns are deliberately discarded.
actor NetworkIdentifier: NetworkIdentifying {

    static let metaURL = URL(string: "https://speed.cloudflare.com/meta")!
    /// How long a lookup is trusted for the same router before refreshing.
    static let cacheLifetime: TimeInterval = 30 * 60

    private var cache: (key: String, info: ISPInfo, fetchedAt: Date)?

    func ispInfo(gatewayIP: String?, interface: InterfaceKind) async -> ISPInfo? {
        let key = interface == .cellular ? "cellular" : (gatewayIP ?? "no-gateway")
        let now = Date()

        if let cache, cache.key == key, now.timeIntervalSince(cache.fetchedAt) < Self.cacheLifetime {
            return cache.info
        }

        if let fresh = await fetch() {
            cache = (key, fresh, now)
            return fresh
        }

        // The lookup failed — most often because the internet is down. An
        // older answer for the same router is still the right identification,
        // and is exactly what lets an outage be filed under the right network.
        if let cache, cache.key == key {
            return cache.info
        }
        return nil
    }

    private func fetch() async -> ISPInfo? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: Self.metaURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // The endpoint refuses requests that do not appear to come from its
        // own speed-test page.
        request.setValue("https://speed.cloudflare.com/", forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return Self.parse(data)
        } catch {
            return nil
        }
    }

    /// Internal for tests.
    static func parse(_ data: Data) -> ISPInfo? {
        struct Meta: Decodable {
            var clientIp: String?
            var asn: Int?
            var asOrganization: String?
            var city: String?
            var region: String?
            var country: String?
        }
        guard
            let meta = try? JSONDecoder().decode(Meta.self, from: data),
            let asn = meta.asn,
            let organization = meta.asOrganization, !organization.isEmpty
        else {
            return nil
        }
        return ISPInfo(
            asn: asn,
            organization: organization,
            publicIP: meta.clientIp,
            city: meta.city,
            region: meta.region,
            country: meta.country
        )
    }
}
