import Foundation

@MainActor
class SocialService: ObservableObject {
    static let shared = SocialService()

    @Published var following: [FollowedUser] = []
    @Published var isLoading = false
    @Published var error: String?

    struct FollowedUser: Identifiable {
        let id: String  // userId
        let handle: String
        let followedAt: String
    }

    private let apiBaseUrl = Config.apiBaseUrl

    var isAuthenticated: Bool {
        KeychainService.shared.get(key: "idToken") != nil
    }

    func isFollowing(handle: String) -> Bool {
        following.contains { $0.handle.lowercased() == handle.lowercased() }
    }

    func follow(handle: String) async {
        guard let url = URL(string: "\(apiBaseUrl)/follow") else { return }
        guard let idToken = KeychainService.shared.get(key: "idToken") else { return }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "targetHandle": handle,
                "action": "follow"
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let userId = json["targetUserId"] as? String {
                let newUser = FollowedUser(id: userId, handle: handle, followedAt: ISO8601DateFormatter().string(from: Date()))
                if !following.contains(where: { $0.handle.lowercased() == handle.lowercased() }) {
                    following.append(newUser)
                }
                Analytics.follow(targetHandle: handle)
            }
        } catch {
            self.error = error.localizedDescription
            Analytics.error("Follow failed", context: "SocialService.follow", underlyingError: error)
        }
    }

    func unfollow(handle: String) async {
        guard let url = URL(string: "\(apiBaseUrl)/follow") else { return }
        guard let idToken = KeychainService.shared.get(key: "idToken") else { return }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "targetHandle": handle,
                "action": "unfollow"
            ])

            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                following.removeAll { $0.handle == handle }
                Analytics.unfollow(targetHandle: handle)
            }
        } catch {
            self.error = error.localizedDescription
            Analytics.error("Unfollow failed", context: "SocialService.unfollow", underlyingError: error)
        }
    }

    func loadFollowingIfNeeded() async {
        guard following.isEmpty else { return }
        await loadFollowing()
    }

    func loadFollowing() async {
        guard let url = URL(string: "\(apiBaseUrl)/me/following") else { return }
        guard let idToken = KeychainService.shared.get(key: "idToken") else { return }

        isLoading = true
        error = nil

        do {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                NotificationCenter.default.post(name: .forceLogout, object: nil)
                isLoading = false
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["following"] as? [[String: Any]] else {
                isLoading = false
                return
            }

            following = items.compactMap { item in
                guard let handle = item["handle"] as? String,
                      let userId = item["userId"] as? String else { return nil }
                return FollowedUser(
                    id: userId,
                    handle: handle,
                    followedAt: item["followedAt"] as? String ?? ""
                )
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}
