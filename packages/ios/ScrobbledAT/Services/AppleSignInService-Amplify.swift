import Foundation
import Amplify
import AWSCognitoAuthPlugin

@MainActor
class AppleSignInService: ObservableObject {
    static let shared = AppleSignInService()
    
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var error: String?
    
    struct User {
        let userId: String
        let email: String
        let name: String?
    }
    
    func signIn() async {
        do {
            let result = try await Amplify.Auth.signInWithWebUI(for: .apple)
            
            if result.isSignedIn {
                await fetchUserAttributes()
                
                // Trigger push notification registration
                await PushNotificationService.shared.registerIfAuthenticated()
            }
        } catch {
            self.error = error.localizedDescription
            print("❌ Sign in failed: \(error)")
        }
    }
    
    func fetchUserAttributes() async {
        do {
            let attributes = try await Amplify.Auth.fetchUserAttributes()
            
            let userId = attributes.first(where: { $0.key == .sub })?.value ?? ""
            let email = attributes.first(where: { $0.key == .email })?.value ?? ""
            let name = attributes.first(where: { $0.key == .name })?.value
            
            currentUser = User(userId: userId, email: email, name: name)
            isAuthenticated = true
            
            print("✅ Signed in as: \(email)")
        } catch {
            self.error = error.localizedDescription
            print("❌ Failed to fetch user attributes: \(error)")
        }
    }
    
    func signOut() async {
        do {
            try await Amplify.Auth.signOut()
            currentUser = nil
            isAuthenticated = false
            print("✅ Signed out")
        } catch {
            self.error = error.localizedDescription
            print("❌ Sign out failed: \(error)")
        }
    }
    
    func checkAuthStatus() async {
        do {
            let session = try await Amplify.Auth.fetchAuthSession()
            if session.isSignedIn {
                await fetchUserAttributes()
            }
        } catch {
            print("Not signed in")
        }
    }
}
