//
//  NetworkEntity.swift
//  RouterWatch
//

import AppIntents
import Foundation

/// One of the user's networks, as Shortcuts sees it.
///
/// Having a real entity rather than a typed-in name means a shortcut can pick
/// "Home Wi-Fi" from a list, keeps working after the network is renamed, and
/// can read the provider and router address in later steps.
struct NetworkEntity: AppEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Network", numericFormat: "\(placeholder: .int) networks")
    }

    static var defaultQuery = NetworkEntityQuery()

    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Internet Provider")
    var provider: String

    @Property(title: "Router Address")
    var routerAddress: String

    @Property(title: "Measurements")
    var measurementCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: routerAddress.isEmpty ? "\(provider)" : "\(provider) · \(routerAddress)"
        )
    }

    init(profile: NetworkProfile, measurementCount: Int) {
        self.id = profile.id
        self.name = profile.displayName
        self.provider = profile.isp?.organization ?? "Unknown provider"
        self.routerAddress = profile.gatewayIP ?? ""
        self.measurementCount = measurementCount
    }
}

struct NetworkEntityQuery: EntityQuery {

    @MainActor
    func entities(for identifiers: [NetworkEntity.ID]) async throws -> [NetworkEntity] {
        let environment = IntentContext.preparedEnvironment()
        return identifiers.compactMap { identifier in
            environment.networks.profile(id: identifier).map {
                NetworkEntity(profile: $0, measurementCount: environment.networks.store(for: $0.id).results.count)
            }
        }
    }

    /// Offered in the Shortcuts picker, current network first.
    @MainActor
    func suggestedEntities() async throws -> [NetworkEntity] {
        let environment = IntentContext.preparedEnvironment()
        return environment.networks.sortedProfiles.map {
            NetworkEntity(profile: $0, measurementCount: environment.networks.store(for: $0.id).results.count)
        }
    }
}

/// Lets a shortcut choose the window statistics are summarised over.
extension TimeRange: AppEnum {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Time Range")
    }

    static var caseDisplayRepresentations: [TimeRange: DisplayRepresentation] {
        [
            .hour24: DisplayRepresentation(title: "Last 24 Hours"),
            .days7: DisplayRepresentation(title: "Last 7 Days"),
            .days30: DisplayRepresentation(title: "Last 30 Days"),
            .all: DisplayRepresentation(title: "All Time")
        ]
    }
}
