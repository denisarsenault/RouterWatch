//
//  NetworkPathMonitor.swift
//  RouterWatch
//

import Foundation
import Network
import Observation

/// Watches the local link so the app can tell "this device is off the network"
/// apart from "the router cannot reach the internet".
///
/// Without this every unplugged cable would be logged as a WAN outage, which
/// would make the error breakdown useless for arguing with an ISP.
@MainActor
@Observable
final class NetworkPathMonitor {
    private(set) var isSatisfied = true
    private(set) var interface: InterfaceKind = .other
    private(set) var isExpensive = false
    private(set) var isConstrained = false
    /// The router's local address on the current path, e.g. `192.168.1.1`.
    private(set) var gatewayIP: String?
    /// Whether the first path report has arrived. Before it has, `gatewayIP`
    /// is unknown rather than absent, and identifying the network would be a
    /// guess that files results under a router-less duplicate of the real one.
    private(set) var hasInitialPath = false
    /// Goes up every time the device moves to a different router, including
    /// by way of being offline. A probe compares it before and after, so that
    /// even a round trip — home, to a hotspot, and back within one test — is
    /// caught, which comparing only the router at each end would miss.
    /// Dropping off and rejoining the same router does not count.
    @ObservationIgnored private(set) var routerChangeCount = 0
    /// Whether the last *connected* path was cellular. Kept across offline
    /// gaps, so Wi-Fi → offline → cellular still counts as a change.
    @ObservationIgnored private var lastConnectedWasCellular: Bool?

    /// Called on the main actor when the path flips between usable and
    /// unusable. Not called for the initial state matching the default, or for
    /// a switch between interfaces that stays usable throughout.
    @ObservationIgnored var onAvailabilityChange: ((Bool) -> Void)?

    /// Called on the main actor when the device moves to a different router
    /// without ever losing connectivity — joining another Wi-Fi network, say,
    /// or plugging into a different Ethernet port.
    @ObservationIgnored var onNetworkChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.mybrightzone.routerwatch.path-monitor")
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let kind = NetworkPathMonitor.interfaceKind(for: path)
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            let gateway = NetworkPathMonitor.gatewayIP(for: path)
            Task { @MainActor [weak self] in
                self?.apply(
                    isSatisfied: satisfied,
                    interface: kind,
                    gatewayIP: gateway,
                    isExpensive: expensive,
                    isConstrained: constrained
                )
            }
        }
        monitor.start(queue: queue)
    }

    /// Records a path update and announces availability changes. Internal
    /// rather than private so tests can simulate the network dropping.
    func apply(
        isSatisfied satisfied: Bool,
        interface kind: InterfaceKind,
        gatewayIP gateway: String? = nil,
        isExpensive expensive: Bool = false,
        isConstrained constrained: Bool = false
    ) {
        if satisfied {
            let isCellular = kind == .cellular
            let movedRouter = gateway != nil && gatewayIP != nil && gateway != gatewayIP
            let changedMedium = lastConnectedWasCellular.map { $0 != isCellular } ?? false
            if hasInitialPath, movedRouter || changedMedium {
                routerChangeCount += 1
            }
            lastConnectedWasCellular = isCellular
        }
        hasInitialPath = true
        let availabilityChanged = isSatisfied != satisfied
        let switchedRouters = !availabilityChanged && satisfied
            && gatewayIP != nil && gateway != nil && gatewayIP != gateway

        isSatisfied = satisfied
        interface = satisfied ? kind : .none
        // Keep the last known router while offline, so an outage can still be
        // filed under the network it happened on.
        if satisfied || gateway != nil {
            gatewayIP = gateway
        }
        isExpensive = expensive
        isConstrained = constrained

        if availabilityChanged {
            onAvailabilityChange?(satisfied)
        } else if switchedRouters {
            onNetworkChange?()
        }
    }

    /// Waits, briefly, for the first path report. It normally arrives within
    /// milliseconds of `start()`; the timeout only guards against a device
    /// with no network stack worth waiting for.
    func waitForInitialPath(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !hasInitialPath, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitor.cancel()
    }

    /// Prefers the IPv4 gateway — it is the address people recognise as "the
    /// router" — and falls back to IPv6 without its interface scope suffix.
    private nonisolated static func gatewayIP(for path: NWPath) -> String? {
        var fallback: String?
        for gateway in path.gateways {
            guard case let .hostPort(host, _) = gateway else { continue }
            switch host {
            case .ipv4(let address):
                return "\(address)"
            case .ipv6(let address):
                if fallback == nil {
                    fallback = "\(address)".components(separatedBy: "%").first
                }
            case .name(let name, _):
                if fallback == nil { fallback = name }
            @unknown default:
                continue
            }
        }
        return fallback
    }

    /// Runs on the monitor's own queue, so it must stay off the main actor.
    private nonisolated static func interfaceKind(for path: NWPath) -> InterfaceKind {
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .other
    }
}
