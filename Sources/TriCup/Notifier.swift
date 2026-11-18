import Foundation
import UserNotifications

/// Small wrapper around user notifications, used for disconnect and low-battery
/// warnings. Falls back to logging when running outside an app bundle.
final class Notifier {
    static let shared = Notifier()

    private init() {}

    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("TriCup: %@ — %@", title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
