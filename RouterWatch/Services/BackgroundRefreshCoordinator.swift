//
//  BackgroundRefreshCoordinator.swift
//  RouterWatch
//

#if os(iOS)

import BackgroundTasks
import Foundation
import OSLog

/// Keeps the schedule ticking on iOS while the app is not in the foreground.
///
/// Worth being blunt about the limits: iOS does not let a third-party app run a
/// speed test every fifteen minutes around the clock. `BGProcessingTask` is
/// opportunistic — the system decides when to run it, typically while the
/// device is charging and on Wi-Fi, and it may skip long stretches entirely.
/// So on iPhone and iPad this app gives continuous coverage in the foreground
/// and best-effort samples in the background, while the Mac build is the one
/// that genuinely monitors all day.
@MainActor
final class BackgroundRefreshCoordinator {

    static let taskIdentifier = "com.mybrightzone.routerwatch.probe"

    private let logger = Logger(subsystem: "com.mybrightzone.routerwatch", category: "BackgroundTask")
    private var probeHandler: (() async -> Void)?

    /// Must be called before the app finishes launching, which is why it runs
    /// from the `App` initialiser rather than from a view's `task`.
    func register(probe: @escaping () async -> Void) {
        probeHandler = probe
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handle(processingTask)
        }
    }

    func schedule(intervalSeconds: TimeInterval) {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: intervalSeconds)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator has no background scheduler; not worth surfacing to the user.
            logger.debug("Could not schedule background probe: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ task: BGProcessingTask) {
        // Re-arm first: if the probe hangs and the system kills us, the next
        // opportunity is already booked.
        schedule(intervalSeconds: 15 * 60)

        let work = Task { @MainActor in
            await probeHandler?()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }
}

#endif
