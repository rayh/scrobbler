import SwiftUI
import PostHog
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(
            name: .didRegisterForRemoteNotificationsWithDeviceTokenNotification,
            object: deviceToken
        )
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ Failed to register for remote notifications: \(error)")
    }
    
    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let config = PostHogConfig(apiKey: Config.postHogApiKey, host: Config.postHogHost)
        PostHogSDK.shared.setup(config)
        return true
    }
    
    
}

extension Notification.Name {
    static let didRegisterForRemoteNotificationsWithDeviceTokenNotification = Notification.Name("didRegisterForRemoteNotificationsWithDeviceToken")
    static let openURL = Notification.Name("openURL")
}

@main
struct ScrobbledATApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var pushService = PushNotificationService.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(pushService)
                .onAppear {
                    Task {
                        await pushService.requestPermission()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .didRegisterForRemoteNotificationsWithDeviceTokenNotification)) { notification in
                    if let deviceToken = notification.object as? Data {
                        pushService.setDeviceToken(deviceToken)
                    }
                }
                .onOpenURL { url in
                    // Deep links are handled by AppRouter inside ContentView.
                    // Post a notification so ContentView's router can pick it up
                    // without needing a direct reference here.
                    NotificationCenter.default.post(name: .openURL, object: url)
                }
        }
    }
}
