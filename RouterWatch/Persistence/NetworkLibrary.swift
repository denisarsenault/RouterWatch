//
//  NetworkLibrary.swift
//  RouterWatch
//

import Foundation
import Observation
import OSLog

/// Every network RouterWatch knows about, each with its own measurement log.
///
/// On disk:
///
///     Application Support/RouterWatch/
///         networks.json                       registry: profiles + active network
///         Networks/<network id>/measurements.json
///
/// Keeping one file per network means results can never bleed between
/// networks, and deleting a network's history is removing one folder.
@MainActor
@Observable
final class NetworkLibrary {

    private(set) var profiles: [NetworkProfile] = []
    /// The network the device is on (or was last on, while offline).
    private(set) var activeNetworkID: String?
    /// The network the dashboard, chart, and log are showing. `nil` follows
    /// the active network, which is what the user wants almost all the time.
    private(set) var viewedNetworkID: String?
    private(set) var lastRegistryError: String?
    /// How many false readings the one-time cleanup removed, for Settings to
    /// report back.
    private(set) var removedArtifactCount = 0

    // MARK: Lookups

    var activeProfile: NetworkProfile? { profile(id: activeNetworkID) }

    var viewedProfile: NetworkProfile? { profile(id: viewedNetworkID ?? activeNetworkID) }

    var isViewingActiveNetwork: Bool {
        viewedNetworkID == nil || viewedNetworkID == activeNetworkID
    }

    /// Newest first — the order people expect in a picker.
    var sortedProfiles: [NetworkProfile] {
        profiles.sorted { lhs, rhs in
            if lhs.isLegacy != rhs.isLegacy { return !lhs.isLegacy }
            return lhs.lastSeen > rhs.lastSeen
        }
    }

    /// Shows another network's results. Pass `nil`, or the active network, to
    /// go back to following whichever network the device is on.
    func view(_ id: String?) {
        viewedNetworkID = (id == activeNetworkID) ? nil : id
    }

    func profile(id: String?) -> NetworkProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// The log the UI should show. An empty, never-saved log before any network
    /// has been identified.
    var viewedStore: MeasurementStore {
        guard let id = viewedProfile?.id else { return emptyStore }
        return store(for: id)
    }

    var activeStore: MeasurementStore {
        guard let id = activeProfile?.id else { return emptyStore }
        return store(for: id)
    }

    /// Loads a network's log on first use.
    func store(for id: String) -> MeasurementStore {
        if let existing = stores[id] {
            return existing
        }
        let store = MeasurementStore(fileURL: measurementsURL(for: id))
        store.load()
        stores[id] = store
        return store
    }

    var totalMeasurementCount: Int {
        profiles.reduce(0) { $0 + store(for: $1.id).results.count }
    }

    // MARK: Identification

    /// Files an observation under a known network, or starts a new one, and
    /// makes it the active network.
    @discardableResult
    func resolve(_ observation: NetworkObservation, now: Date = Date()) -> NetworkProfile {
        var profile: NetworkProfile
        if let match = NetworkMatcher.bestMatch(for: observation, in: profiles),
           let index = profiles.firstIndex(where: { $0.id == match.id }) {
            profiles[index].absorb(observation, now: now)
            profile = profiles[index]
        } else {
            profile = NetworkProfile(observation: observation, now: now)
            profiles.append(profile)
            logger.notice("New network identified: \(profile.automaticName, privacy: .private)")
        }

        activeNetworkID = profile.id
        saveRegistry()
        return profile
    }

    /// Where a probe that ran with no network path at all should be filed.
    ///
    /// The device is on no network, so the outage belongs to the one it was on
    /// — "home Wi-Fi dropped" is the fact worth recording.
    func networkForOfflineProbe(now: Date = Date()) -> NetworkProfile {
        if let active = activeProfile {
            return active
        }
        if let recent = profiles.filter({ !$0.isLegacy }).max(by: { $0.lastSeen < $1.lastSeen }) {
            activeNetworkID = recent.id
            saveRegistry()
            return recent
        }
        return resolve(NetworkObservation(interface: .none, gatewayIP: nil, isp: nil), now: now)
    }

    // MARK: Editing

    func rename(_ id: String, to name: String?) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        saveRegistry()
    }

    /// Removes a network and its entire measurement history.
    func delete(_ id: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        stores[id]?.flushPendingWrites()
        stores[id] = nil
        profiles.remove(at: index)
        try? FileManager.default.removeItem(at: directory(for: id))

        if activeNetworkID == id { activeNetworkID = nil }
        if viewedNetworkID == id { viewedNetworkID = nil }
        saveRegistry()
    }

    /// One-time cleanup of readings recorded before refusals were rejected.
    @discardableResult
    func removeRefusalArtifacts() -> Int {
        var removed = 0
        for profile in profiles {
            let store = store(for: profile.id)
            let count = store.removeRefusalArtifacts()
            if count > 0 {
                store.save()
                removed += count
            }
        }
        removedArtifactCount = removed
        if removed > 0 {
            logger.notice("Removed \(removed, privacy: .public) false readings left by throttled test servers")
        }
        return removed
    }

    /// Folds router-less duplicates back into the network they came from.
    ///
    /// Earlier builds could identify a network before the path monitor had
    /// reported the router, creating a second profile — same ISP, no router
    /// address — that the next probe never matched again. Its results belong
    /// to the real network.
    ///
    /// Deliberately conservative: a duplicate is merged only when exactly one
    /// real network shares its ISP. With two candidates there is no way to
    /// know which one it was, so it is left alone for the user to sort out.
    @discardableResult
    func mergeRouterlessDuplicates() -> Int {
        var merged = 0
        for orphan in profiles where !orphan.isLegacy && !orphan.isCellular && orphan.gatewayIP == nil {
            guard let asn = orphan.isp?.asn else { continue }
            let candidates = profiles.filter {
                $0.id != orphan.id && !$0.isLegacy && !$0.isCellular && $0.gatewayIP != nil && $0.isp?.asn == asn
            }
            guard candidates.count == 1, let target = candidates.first,
                  let targetIndex = profiles.firstIndex(where: { $0.id == target.id }) else { continue }

            // Move the results first and make sure they are on disk before the
            // duplicate's folder is removed.
            let destination = store(for: target.id)
            let existingIDs = Set(destination.results.map(\.id))
            let moved = store(for: orphan.id).results
                .filter { !existingIDs.contains($0.id) }
                .map { result -> ProbeResult in
                    var result = result
                    result.networkID = target.id
                    return result
                }
            destination.merge(moved)
            destination.save()
            destination.flushPendingWrites()

            profiles[targetIndex].firstSeen = min(profiles[targetIndex].firstSeen, orphan.firstSeen)
            profiles[targetIndex].lastSeen = max(profiles[targetIndex].lastSeen, orphan.lastSeen)
            for kind in orphan.interfacesSeen where !profiles[targetIndex].interfacesSeen.contains(kind) {
                profiles[targetIndex].interfacesSeen.append(kind)
            }
            if profiles[targetIndex].customName == nil {
                profiles[targetIndex].customName = orphan.customName
            }
            if activeNetworkID == orphan.id { activeNetworkID = target.id }

            delete(orphan.id)
            merged += 1
            logger.notice("Merged \(moved.count, privacy: .public) results from a router-less duplicate network")
        }
        if merged > 0 {
            saveRegistry()
        }
        return merged
    }

    func pruneAll(retentionDays: Int, now: Date = Date()) {
        for profile in profiles {
            let store = store(for: profile.id)
            if store.prune(retentionDays: retentionDays, now: now) > 0 {
                store.save()
            }
        }
    }

    // MARK: Persistence

    @ObservationIgnored private var stores: [String: MeasurementStore] = [:]
    @ObservationIgnored private let rootDirectory: URL
    @ObservationIgnored private let emptyStore: MeasurementStore
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.mybrightzone.routerwatch",
        category: "Networks"
    )

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        self.emptyStore = MeasurementStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("routerwatch-empty-\(UUID().uuidString).json")
        )
    }

    nonisolated static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RouterWatch", isDirectory: true)
    }

    private var registryURL: URL { rootDirectory.appendingPathComponent("networks.json") }

    private func directory(for id: String) -> URL {
        rootDirectory
            .appendingPathComponent("Networks", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    private func measurementsURL(for id: String) -> URL {
        directory(for: id).appendingPathComponent("measurements.json")
    }

    private struct Registry: Codable {
        var profiles: [NetworkProfile]
        var activeNetworkID: String?
    }

    func load() {
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: registryURL.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let registry = try decoder.decode(Registry.self, from: Data(contentsOf: registryURL))
                profiles = registry.profiles
                activeNetworkID = registry.activeNetworkID
            } catch {
                // Keep the measurement folders; only the index is unreadable.
                logger.error("Could not read network registry: \(error.localizedDescription, privacy: .public)")
                let salvage = registryURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: salvage)
                try? FileManager.default.moveItem(at: registryURL, to: salvage)
            }
        }

        migrateSingleLogIfNeeded()
    }

    /// Before networks were tracked, everything went into one
    /// `measurements.json`. It moves into its own "earlier results" network,
    /// untouched, rather than being guessed onto whichever network is current.
    private func migrateSingleLogIfNeeded() {
        let legacyFile = rootDirectory.appendingPathComponent("measurements.json")
        guard FileManager.default.fileExists(atPath: legacyFile.path) else { return }

        let legacyStore = MeasurementStore(fileURL: legacyFile)
        legacyStore.load()
        guard let first = legacyStore.results.first, let last = legacyStore.results.last else {
            try? FileManager.default.removeItem(at: legacyFile)
            return
        }

        // Merge rather than replace. An older build of the app, run after a
        // migration, recreates the single log — and overwriting would throw
        // away everything migrated the first time.
        let destination = store(for: NetworkProfile.legacyID)
        let existingIDs = Set(destination.results.map(\.id))
        let incoming = legacyStore.results.filter { !existingIDs.contains($0.id) }
        destination.merge(incoming)
        destination.save()
        destination.flushPendingWrites()

        do {
            try FileManager.default.removeItem(at: legacyFile)
        } catch {
            logger.error("Could not remove the migrated log: \(error.localizedDescription, privacy: .public)")
        }

        if let index = profiles.firstIndex(where: { $0.id == NetworkProfile.legacyID }) {
            profiles[index].lastSeen = max(profiles[index].lastSeen, last.timestamp)
        } else {
            profiles.append(.legacy(firstSeen: first.timestamp, lastSeen: last.timestamp))
        }
        saveRegistry()
        logger.notice("Moved \(incoming.count, privacy: .public) earlier results into their own network")
    }

    private func saveRegistry() {
        do {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Registry(profiles: profiles, activeNetworkID: activeNetworkID))
            try data.write(to: registryURL, options: .atomic)
            lastRegistryError = nil
        } catch {
            lastRegistryError = error.localizedDescription
            logger.error("Could not save network registry: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Waits for every network's pending writes. Tests use it before reading
    /// files back from disk.
    func flushPendingWrites() {
        stores.values.forEach { $0.flushPendingWrites() }
    }
}
