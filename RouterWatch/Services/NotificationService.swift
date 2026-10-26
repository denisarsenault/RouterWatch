//
//  NotificationService.swift
//  RouterWatch
//

import Foundation
import OSLog

#if !os(tvOS)
import UserNotifications
#endif

/// Posts a local notification when a probe fails.
///
/// tvOS has no local notifications, so on that platform every entry point here
/// is a no-op and the UI hides the corresponding setting.
@MainActor
final class NotificationService {

    private let logger = Logger(subsystem: "com.mybrightzone.routerwatch", category: "Notifications")

    /// Suppresses repeat alerts while an outage is ongoing — a router that is
    /// down for six hours should produce one notification, not twenty-four.
    private var lastNotifiedKind: ErrorKind?

    var isSupported: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }

    func requestAuthorizationIfNeeded() async {
        #if !os(tvOS)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// - Parameter recoveredAfter: How long the connection was down, when this
    ///   result ends an outage.
    func handle(result: ProbeResult, notifiesOnFailure: Bool, recoveredAfter: TimeInterval? = nil) {
        guard notifiesOnFailure else { return }

        // Only announce a recovery the user was told about. An outage that
        // began before a relaunch, or while alerts were off, ends quietly.
        if let recoveredAfter, lastNotifiedKind?.isHardFailure == true {
            var body = "Back online after \(Format.duration(recoveredAfter))."
            if let mbps = result.downloadMbps {
                body += " Download is \(Format.mbps(mbps))."
            }
            post(title: "Connection restored", body: body)
        }

        guard let kind = result.errorKind else {
            // Recovery: clear the suppression so the next failure alerts again.
            lastNotifiedKind = nil
            return
        }

        guard kind != lastNotifiedKind else { return }
        lastNotifiedKind = kind
        post(title: "Connection problem: \(kind.title)", body: result.errorDetail ?? kind.explanation)
    }

    private func post(title: String, body: String) {
        #if !os(tvOS)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error {
                logger.error("Could not post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }
}
