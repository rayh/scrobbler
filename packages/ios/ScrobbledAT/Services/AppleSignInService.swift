import AuthenticationServices
import os.log

@MainActor
class AppleSignInService: NSObject, ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var isLoading = false
    @Published var error: String?

    struct User {
        let handle: String?
        let name: String?
    }

    private let apiBaseUrl = Config.apiBaseUrl

    override init() {
        super.init()
        checkExistingAuth()
    }

    private func checkExistingAuth() {
        guard let idToken = KeychainService.shared.get(key: "idToken") else { return }

        // Decode the JWT exp claim without verifying signature — just to check expiry.
        // A fully expired token will 403 every API call and would log the user out anyway;
        // clearing it eagerly here avoids that round-trip and shows the login screen immediately.
        let parts = idToken.split(separator: ".")
        guard parts.count == 3 else {
            self.isAuthenticated = true
            return
        }

        // Base64url → Base64 (add padding to make length a multiple of 4)
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = b64.count % 4
        if remainder != 0 { b64 += String(repeating: "=", count: 4 - remainder) }

        guard let payloadData = Data(base64Encoded: b64),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let exp = payload["exp"] as? TimeInterval else {
            // Can't decode expiry — treat as valid and let the server decide
            self.isAuthenticated = true
            return
        }

        if Date(timeIntervalSince1970: exp) > Date() {
            self.isAuthenticated = true
        } else {
            Log.auth.info("Stored idToken is expired — clearing keychain")
            KeychainService.shared.clear()
        }
    }

    func signInWithApple() {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func signOut() {
        KeychainService.shared.clear()
        currentUser = nil
        isAuthenticated = false
        Analytics.reset()

        UserDefaults.standard.removeObject(forKey: "userProfile")
        if let sharedDefaults = UserDefaults(suiteName: "group.net.wirestorm.scrobbler") {
            sharedDefaults.removeObject(forKey: "isAuthenticated")
            sharedDefaults.removeObject(forKey: "userProfile")
        }
    }
}

extension AppleSignInService: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = credential.identityToken,
              let tokenString = String(data: identityToken, encoding: .utf8) else {
            self.error = "Failed to get Apple identity token"
            Log.auth.error("Failed to extract identity token from ASAuthorizationAppleIDCredential")
            return
        }

        isLoading = true

        Task {
            do {
                guard let url = URL(string: "\(apiBaseUrl)/auth/apple") else { return }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let body: [String: Any] = [
                    "identityToken": tokenString,
                    "user": credential.user,
                    "email": credential.email ?? "",
                    "name": [credential.fullName?.givenName, credential.fullName?.familyName]
                        .compactMap { $0 }
                        .joined(separator: " ")
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                Log.auth.info("POST /auth/apple → sending (user: \(credential.user))")
                let (data, urlResponse) = try await URLSession.shared.data(for: request)
                let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
                let rawBody = String(data: data, encoding: .utf8) ?? "(unreadable)"
                Log.auth.info("POST /auth/apple → HTTP \(statusCode)")

                guard statusCode == 200 else {
                    Log.auth.error("POST /auth/apple non-200 response (\(statusCode)): \(rawBody)")
                    await MainActor.run {
                        self.error = "Server error \(statusCode): \(rawBody)"
                        self.isLoading = false
                    }
                    return
                }

                guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    Log.auth.error("POST /auth/apple response was not a JSON object: \(rawBody)")
                    await MainActor.run {
                        self.error = "Unexpected response format: \(rawBody)"
                        self.isLoading = false
                    }
                    return
                }

                await MainActor.run {
                    if let idToken = response["idToken"] as? String,
                       let accessToken = response["accessToken"] as? String,
                       let refreshToken = response["refreshToken"] as? String {

                        KeychainService.shared.save(key: "idToken", value: idToken)
                        KeychainService.shared.save(key: "accessToken", value: accessToken)
                        KeychainService.shared.save(key: "refreshToken", value: refreshToken)

                        self.isAuthenticated = true

                        // Identify the user in PostHog — userId from JWT sub
                        if let sub = self.jwtSub(from: idToken) {
                            Analytics.identify(userId: sub, handle: response["handle"] as? String ?? "")
                        }

                        // hasHandle is the authoritative signal — always present and accurate.
                        // existingUser can be false for returning users in recovery scenarios
                        // (e.g. after a dev data clear), so don't rely on it for navigation.
                        let hasHandle = response["hasHandle"] as? Bool ?? false
                        Log.auth.info("Apple Sign In succeeded — hasHandle: \(hasHandle)")

                        if !hasHandle {
                            NotificationCenter.default.post(
                                name: .showHandleSelection,
                                object: ["appleUserId": credential.user]
                            )
                        }

                        Task {
                            await PushNotificationService.shared.registerIfAuthenticated()
                        }
                    } else {
                        Log.auth.error("POST /auth/apple missing token fields in response: \(rawBody)")
                        self.error = "Sign in failed: missing token fields. Response: \(rawBody)"
                    }
                    self.isLoading = false
                }
            } catch {
                Log.auth.error("Apple Sign In threw: \(error)")
                Analytics.error("Apple Sign In failed", context: "AppleSignInService", underlyingError: error)
                await MainActor.run {
                    self.error = "Sign in failed: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Log.auth.error("ASAuthorization error: \(error)")
        self.error = error.localizedDescription
        self.isLoading = false
    }
}

extension AppleSignInService: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return ASPresentationAnchor()
    }
}

// MARK: - Helpers

private extension AppleSignInService {
    func jwtSub(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["sub"] as? String
    }
}

extension Notification.Name {
    static let showHandleSelection = Notification.Name("showHandleSelection")
    static let forceLogout = Notification.Name("forceLogout")
}
