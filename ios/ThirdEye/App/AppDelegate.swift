import UIKit
import UserNotifications

/// Push-notification plumbing: the device token for the Windows monitor.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationHandler.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MonitorStore.shared.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Usually the build lacks the Push Notifications capability; Settings → Alerts shows this.
        MonitorStore.shared.pushRegistrationError = error.localizedDescription
    }
}

/// Shows alerts while the app is open and opens the right trade when one is tapped.
/// Kept off the main actor because the notification center calls it from its own queue.
nonisolated final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationHandler()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let tradeID = (response.notification.request.content.userInfo["tradeID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            if let tradeID { MonitorStore.shared.openTradeID = tradeID }
        }
        completionHandler()
    }
}
