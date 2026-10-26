//
//  LoginItemManager.swift
//  RouterWatch
//

#if os(macOS)

import AppKit
import Observation
import OSLog
import ServiceManagement

/// Registers RouterWatch as a login item so all-day monitoring survives a
/// reboot without the user having to remember to launch it.
///
/// `SMAppService.mainApp` is the sanctioned, sandbox-safe route and is what the
/// App Store expects; the old `LSSharedFileList` and login-item helper-bundle
/// approaches are both deprecated and would fail review.
@MainActor
@Observable
final class LoginItemManager {

    /// Mirrors the real system state, which can diverge from our preference —
    /// the user can remove the login item in System Settings at any time, and
    /// macOS can park a newly registered item in "requires approval".
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    @ObservationIgnored private let logger = Logger(
        subsystem: "com.mybrightzone.routerwatch",
        category: "LoginItem"
    )

    init() {
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    /// Returns `true` when the system state ended up matching the request.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            logger.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
        return isEnabled == enabled
    }

    /// Opens the Login Items pane so the user can approve a pending item.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var statusDescription: String {
        switch status {
        case .enabled: return "RouterWatch starts automatically at login."
        case .requiresApproval: return "Approval needed in System Settings › General › Login Items."
        case .notRegistered: return "RouterWatch does not start automatically."
        case .notFound: return "The login item could not be found. Try relaunching from Applications."
        @unknown default: return "Unknown login item state."
        }
    }
}

#endif
