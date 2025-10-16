import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return true
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter,
                              willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .sound]) // visionOS zeigt dezenten Banner
  }
}

enum NotificationHelper {
  static func requestAuthorization(storedAppModel: StoredAppModel) async {
    guard storedAppModel.showNotifications else { return }

    let center = UNUserNotificationCenter.current()
    do {
      let result = try await center.requestAuthorization(options: [.alert, .sound, .badge])
      await MainActor.run {
        storedAppModel.showNotifications = result
      }
    } catch {
      await MainActor.run {
        storedAppModel.showNotifications = false
      }
    }
  }

  static func notify(title: String,
                     body: String,
                     sound: UNNotificationSound? = .default) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = sound

    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
    UNUserNotificationCenter.current().add(req)
  }
}

public class GUINotifier: NotificationBase {

  public func silent(title: String, message: String) {
    NotificationHelper.notify(title: title, body: message, sound: nil)
  }

  public func normal(title: String, message: String) {
    NotificationHelper.notify(title: title, body: message, sound: .default)
  }

  public func critical(title: String, message: String) {
    NotificationHelper
      .notify(title: title, body: message, sound: .defaultCritical)
  }
}

