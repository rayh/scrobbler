import Foundation
import UserNotifications
import UIKit

@MainActor
class PushNotificationService: NSObject, ObservableObject {
    static let shared = PushNotificationService()
    
    @Published var isRegistered = false
    @Published var deviceToken: String?
    @Published var error: String?
    
    // In-memory only — cleared on every app launch, preventing redundant mid-session calls
    // but ensuring we always re-register on a fresh launch.
    private var registeredThisSession = false
    
    override init() {
        super.init()
    }
    
    func requestPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            
            if granted {
                await registerForRemoteNotifications()
            } else {
                error = "Push notification permission denied"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    private func registerForRemoteNotifications() async {
        await UIApplication.shared.registerForRemoteNotifications()
    }
    
    func setDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02.2hhx", $0) }.joined()
        self.deviceToken = token
        
        print("📱 DEVICE TOKEN: \(token)")
        
        // Always persist the latest token. If it changed, clear the registered flag
        // so we re-register with the backend on this launch.
        let previousToken = UserDefaults.standard.string(forKey: "deviceToken")
        if previousToken != token {
            UserDefaults.standard.removeObject(forKey: "registeredToken")
        }
        UserDefaults.standard.set(token, forKey: "deviceToken")
        
        // Try to register if already authenticated
        Task {
            await registerIfAuthenticated()
        }
    }
    
    func registerIfAuthenticated() async {
        guard let token = UserDefaults.standard.string(forKey: "deviceToken") else {
            print("⏳ No device token yet")
            return
        }
        
        // Check if user is authenticated
        guard KeychainService.shared.get(key: "idToken") != nil else {
            print("⏳ Waiting for authentication to register push notifications")
            return
        }

        // Skip if already registered in this session (prevents duplicate calls e.g.
        // if both setDeviceToken and post-login registerIfAuthenticated fire together).
        if registeredThisSession {
            print("✅ Push already registered this session")
            isRegistered = true
            return
        }
        
        await registerWithBackend(token: token)
    }
    
    private func registerWithBackend(token: String) async {
        do {
            guard let idToken = KeychainService.shared.get(key: "idToken") else { return }

            let apiUrl = "\(Config.apiBaseUrl)/push/register"
            guard let url = URL(string: apiUrl) else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")

            // TODO: Add JWT token from Cognito for authorization

            let requestBody = [
                "deviceToken": token,
                "platform": "ios"
            ]

            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

            let (data, urlResponse) = try await URLSession.shared.data(for: request)

            // Surface non-2xx as a readable error rather than crashing on unexpected JSON shape
            if let http = urlResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "(empty)"
                print("❌ Push registration HTTP \(http.statusCode): \(body)")
                self.error = "Push registration failed (\(http.statusCode))"
                return
            }

            let response = try JSONDecoder().decode(RegisterResponse.self, from: data)

            isRegistered = true
            registeredThisSession = true
            UserDefaults.standard.removeObject(forKey: "pendingDeviceToken") // clean up old key if present
            print("✅ Push notification registered: \(response.endpointArn)")

        } catch {
            self.error = error.localizedDescription
            print("❌ Push registration failed: \(error)")
        }
    }

    struct RegisterResponse: Codable {
        let status: String?   // optional — server may omit on error paths
        let endpointArn: String
    }
    
    func handleNotification(_ userInfo: [AnyHashable: Any]) {
        // Handle incoming push notification
        print("📱 Received push notification: \(userInfo)")
        
        if let data = userInfo["data"] as? String,
           let jsonData = data.data(using: .utf8),
           let notificationData = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            
            let type = notificationData["type"] as? String
            
            switch type {
            case "follow_post":
                // Handle follower post notification
                break
            case "location_post":
                // Handle location-based notification
                break
            default:
                break
            }
        }
    }
}
