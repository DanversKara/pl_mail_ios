import OSLog
import PLMailCore
import UIKit
import UserNotifications

/// The bit of push that has to be a `UIApplicationDelegate`.
///
/// SwiftUI has no equivalent hook for the device token — the callback is only
/// delivered to an app delegate — so this exists purely to catch it and hand
/// it on.
///
/// **The honesty rule this enforces.** A push here means "something changed",
/// never "here is your mail": the payload carries no subject, no sender and no
/// body, so nothing about the mail passes through Apple. That means the
/// notification cannot say who wrote to you until the app has fetched, which
/// is a deliberate trade — a self-hosted mail client whose whole point is that
/// the mail stays on your server should not be relaying its contents through a
/// third party for the sake of a nicer banner.
@MainActor
final class PushDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "de.plmail", category: "push")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        logger.notice("Push delegate installed.")

        return true
    }

    /// Set by the app once it has a connection to register against.
    var onToken: ((Data) async -> Void)?
    /// Called when a push says the mailbox moved.
    var onSilentPush: (() async -> Void)?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        logger.info("Device token received (\(deviceToken.count) bytes).")

        Task { await onToken?(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        // Routine on a simulator without a push entitlement, and not worth a
        // dialog anywhere: the app already refreshes on foreground and in the
        // background, so the failure costs latency, not mail.
        NSLog("Remote notification registration failed: \(error.localizedDescription)")
    }

    /// A silent push.
    ///
    /// The completion-handler form, not the `async` one. The async variant
    /// compiles and looks equivalent, but UIKit never called it — the system
    /// log showed `UIFetchContentInBackgroundAction` being delivered to the
    /// scene while this method sat unused. Only the selector below is looked
    /// up.
    ///
    /// The result matters: iOS throttles an app that reports `.newData` every
    /// time and delivers nothing, so an unconnected app says `.noData` and
    /// means it.
    @objc func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler:
            @escaping (UIBackgroundFetchResult) -> Void
    ) {
        logger.notice("Silent push received.")

        // `@objc` and not `nonisolated`, both deliberately. Without `@objc`
        // the selector is not emitted at all and UIKit answers the fetch
        // action itself — the system log shows it decoded and replied to in
        // the same millisecond, with nothing in between. Marking it
        // `nonisolated` had the same effect.
        let finish = UncheckedSendable(completionHandler)

        Task { @MainActor in
            guard let onSilentPush else {
                logger.info("Nothing signed in; ignoring the push.")
                finish.value(.noData)

                return
            }

            await onSilentPush()
            logger.notice("Silent push handled.")
            finish.value(.newData)
        }
    }
}

extension PushDelegate {
    /// Asks for permission and registers.
    ///
    /// Deliberately **not** called at first launch, and not called at all
    /// unless the server says it can actually send a push. A permission prompt
    /// before someone has seen a single message is the prompt everybody
    /// denies, and a denial is close to permanent — it can only be undone in
    /// Settings. Spending that one chance on a server with no APNs sender,
    /// where granting it would deliver precisely nothing, is worse than not
    /// asking.
    static func requestAuthorization() async {
        let centre = UNUserNotificationCenter.current()

        guard
            let granted = try? await centre.requestAuthorization(options: [.alert, .badge, .sound]),
            granted
        else { return }

        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Registers for silent pushes only, which needs no permission at all.
    ///
    /// Worth doing even when someone has refused notifications: a silent push
    /// still wakes the app to sync, so the mail is already there when they
    /// next look. Refusing banners is not the same as refusing fresh mail.
    static func registerForSilentPushes() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

/// UIKit's completion handler, carried across an actor hop.
///
/// Safe because it is called exactly once, on the main actor, and UIKit's own
/// contract is that it may be called from any thread.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
