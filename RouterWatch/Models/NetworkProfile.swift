//
//  NetworkProfile.swift
//  RouterWatch
//

import Foundation

/// Who provides a network's internet connection, as seen from the outside.
struct ISPInfo: Codable, Hashable, Sendable {
    /// Autonomous System Number — the stable identifier for the provider.
    var asn: Int
    var organization: String
    var publicIP: String?
    var city: String?
    var region: String?
    var country: String?

    var locationDescription: String? {
        let parts = [city, region, country].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// What the device can see about the network it is on at the moment a probe
/// runs. Matched against known `NetworkProfile`s to decide where the result
/// belongs.
struct NetworkObservation: Sendable, Equatable {
    var interface: InterfaceKind
    /// The router's local address, e.g. `192.168.1.1`. Known even while the
    /// internet is down, which is what lets outages be filed correctly.
    var gatewayIP: String?
    /// `nil` while the internet is unreachable or the lookup failed.
    var isp: ISPInfo?

    var isCellular: Bool { interface == .cellular }
}

/// One network RouterWatch has measured. Each has its own measurement log on
/// disk, so results from home, the office, and a phone hotspot never mix.
///
/// Identification uses only what an App Store app can see without asking for
/// permission: the ISP (by AS number) and the router's local address. Wi-Fi
/// names need Location access, and router hardware addresses are hidden from
/// third-party apps entirely. Wi-Fi and Ethernet on the same router are the
/// same network — the interface is recorded per result instead.
struct NetworkProfile: Codable, Identifiable, Hashable, Sendable {
    var id: String
    /// Set by the user; overrides the automatic name.
    var customName: String?
    var gatewayIP: String?
    var isCellular: Bool
    var isp: ISPInfo?
    var interfacesSeen: [InterfaceKind]
    var firstSeen: Date
    var lastSeen: Date
    /// Results recorded before RouterWatch tracked networks. Never matched to
    /// a live network, because there is no way to know which one they were.
    var isLegacy: Bool = false

    static let legacyID = "legacy"

    var displayName: String {
        if let customName, !customName.trimmingCharacters(in: .whitespaces).isEmpty {
            return customName
        }
        return automaticName
    }

    /// e.g. "Charter Communications Inc · 192.168.1.1" or "T-Mobile USA (cellular)".
    var automaticName: String {
        if isLegacy { return "Earlier results (network not recorded)" }
        let provider = isp?.organization ?? "Unknown provider"
        if isCellular { return "\(provider) (cellular)" }
        if let gatewayIP { return "\(provider) · \(gatewayIP)" }
        return provider
    }

    init(id: String = NetworkProfile.makeID(), observation: NetworkObservation, now: Date) {
        self.id = id
        self.customName = nil
        self.gatewayIP = observation.isCellular ? nil : observation.gatewayIP
        self.isCellular = observation.isCellular
        self.isp = observation.isp
        self.interfacesSeen = observation.interface == .none ? [] : [observation.interface]
        self.firstSeen = now
        self.lastSeen = now
    }

    static func legacy(firstSeen: Date, lastSeen: Date) -> NetworkProfile {
        var profile = NetworkProfile(
            id: legacyID,
            observation: NetworkObservation(interface: .none, gatewayIP: nil, isp: nil),
            now: firstSeen
        )
        profile.lastSeen = lastSeen
        profile.isLegacy = true
        return profile
    }

    /// Short, filesystem-safe, and not derived from any network detail, so a
    /// folder name never leaks an IP address.
    static func makeID() -> String {
        "net-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    /// Folds a fresh observation into the profile.
    mutating func absorb(_ observation: NetworkObservation, now: Date) {
        lastSeen = max(lastSeen, now)
        if let isp = observation.isp {
            // Keeps the public IP and location current; the ASN is unchanged
            // by construction, because matching required it.
            self.isp = isp
        }
        if !isCellular, gatewayIP == nil {
            gatewayIP = observation.gatewayIP
        }
        if observation.interface != .none, !interfacesSeen.contains(observation.interface) {
            interfacesSeen.append(observation.interface)
        }
    }
}

/// Decides which known network an observation belongs to. Pure, so the rules
/// are easy to test and easy to read in one place.
enum NetworkMatcher {

    /// - Returns: The matching profile, or `nil` if this is a new network.
    ///
    /// Rules, in order:
    /// 1. Only live profiles of the same kind (cellular vs. not) are considered.
    /// 2. Non-cellular networks must share the router's local address.
    ///    Cellular networks have no meaningful gateway and match on ISP alone.
    /// 3. When the ISP is known, a profile with the same AS number wins. A
    ///    profile whose ISP was never learned (first seen during an outage) is
    ///    claimed next, so it is upgraded rather than duplicated.
    /// 4. When the ISP is unknown — typically because the internet is down —
    ///    the most recently used candidate is assumed. The router is the same
    ///    one, and "the network you were just on" is by far the likeliest answer.
    static func bestMatch(for observation: NetworkObservation, in profiles: [NetworkProfile]) -> NetworkProfile? {
        let candidates = profiles.filter { profile in
            guard !profile.isLegacy, profile.isCellular == observation.isCellular else { return false }
            if observation.isCellular {
                return true
            }
            return profile.gatewayIP == observation.gatewayIP
        }

        func mostRecent(_ list: [NetworkProfile]) -> NetworkProfile? {
            list.max { $0.lastSeen < $1.lastSeen }
        }

        guard let isp = observation.isp else {
            return mostRecent(candidates)
        }

        if let exact = mostRecent(candidates.filter { $0.isp?.asn == isp.asn }) {
            return exact
        }
        return mostRecent(candidates.filter { $0.isp == nil })
    }
}
