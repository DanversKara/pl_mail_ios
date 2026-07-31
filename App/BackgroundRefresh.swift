import BackgroundTasks
import OSLog
import PLMailCore

/// Registers and schedules the periodic background pull.
///
/// Fifteen minutes, matching the server's own scheduled sync. Being more
/// eager buys nothing — the mail is not there yet — and costs a wake-up on a
/// device and a request against someone's home server.
///
/// This is not push. Without APNs there is no true background delivery, and
/// the UI says "last checked" rather than pretending otherwise.
enum BackgroundRefresh {
    static let identifier = "de.plmail.refresh"
    private static let logger = Logger(subsystem: "de.plmail", category: "background")

    static func register(refresh: @escaping @Sendable () async -> Void) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            // Rescheduled first: a run that crashes or is cut short must not
            // be the last one that was ever scheduled.
            schedule()

            // The task object is not Sendable, so completion is signalled
            // through a value the closure can safely capture.
            nonisolated(unsafe) let bgTask = task

            let work = Task {
                await refresh()
                bgTask.setTaskCompleted(success: true)
            }

            bgTask.expirationHandler = {
                work.cancel()
                logger.notice("Background refresh expired before finishing.")
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected in the simulator and whenever the user has switched
            // Background App Refresh off — not worth surfacing.
            logger.debug("Could not schedule: \(error, privacy: .public)")
        }
    }
}
