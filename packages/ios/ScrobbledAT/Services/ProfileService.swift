import Foundation
import UIKit
import CoreLocation

@MainActor
class ProfileService: ObservableObject {
    static let shared = ProfileService()

    @Published var profile: UserProfile?
    @Published var posts: [UserProfileData.UserProfilePost] = []
    @Published var isLoading = false
    @Published var isUploadingAvatar = false
    @Published var error: String?

    struct UserProfile {
        var userId: String
        var handle: String
        var name: String?
        var bio: String?
        var avatarUrl: String?
        var location: ProfileLocation?
        var createdAt: String?
        var followersCount: Int
        var followingCount: Int
    }

    struct ProfileLocation: Codable {
        var city: String?
        var country: String?

        var displayString: String? {
            [city, country].compactMap { $0 }.joined(separator: ", ").nonEmpty
        }
    }

    private let apiBaseUrl = Config.apiBaseUrl
    private static let cacheTTL: TimeInterval = 30
    private var lastLoadedAt: Date?

    // MARK: - Computed: own profile as UserProfileData (for UserProfileView)

    var ownProfileData: UserProfileData? {
        guard let p = profile else { return nil }
        return UserProfileData(
            userId: p.userId,
            handle: p.handle,
            name: p.name,
            bio: p.bio,
            avatarUrl: p.avatarUrl,
            locationCity: p.location?.city,
            locationCountry: p.location?.country,
            createdAt: p.createdAt,
            followersCount: p.followersCount,
            followingCount: p.followingCount,
            posts: posts
        )
    }

    // MARK: - Load own profile + posts

    func loadMyProfile(force: Bool = false) async {
        guard force || profile == nil || lastLoadedAt.map({ Date().timeIntervalSince($0) > Self.cacheTTL }) ?? true else {
            print("⏭️ ProfileService: loadMyProfile — cache still fresh, skipping")
            return
        }
        guard !isLoading else {
            print("⏭️ ProfileService: loadMyProfile — already in flight, skipping")
            return
        }
        guard let idToken = KeychainService.shared.get(key: "idToken") else { return }
        isLoading = true
        error = nil
        do {
            var profileReq = URLRequest(url: URL(string: "\(apiBaseUrl)/me")!)
            profileReq.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")

            var postsReq = URLRequest(url: URL(string: "\(apiBaseUrl)/me/posts")!)
            postsReq.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")

            async let profileFetch = URLSession.shared.data(for: profileReq)
            async let postsFetch = URLSession.shared.data(for: postsReq)

            let (profileData, _) = try await profileFetch
            let (postsData, _) = try await postsFetch

            guard let profileJson = try JSONSerialization.jsonObject(with: profileData) as? [String: Any] else {
                isLoading = false; return
            }
            let postsArray = (try? JSONSerialization.jsonObject(with: postsData) as? [String: Any])?["posts"] as? [[String: Any]] ?? []

            profile = parseProfile(profileJson)
            posts = parsePosts(postsArray)
            lastLoadedAt = Date()

            if let p = profile {
                Analytics.identify(
                    userId: p.userId,
                    handle: p.handle,
                    name: p.name,
                    locationCity: p.location?.city,
                    locationCountry: p.location?.country,
                    createdAt: p.createdAt
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Update bio / location

    func updateProfile(bio: String? = nil, location: ProfileLocation? = nil) async {
        guard let idToken = KeychainService.shared.get(key: "idToken") else { return }
        do {
            var body: [String: Any] = [:]
            if let bio { body["bio"] = bio }
            if let location {
                var loc: [String: String] = [:]
                if let c = location.city { loc["city"] = c }
                if let c = location.country { loc["country"] = c }
                body["location"] = loc
            }
            var req = URLRequest(url: URL(string: "\(apiBaseUrl)/me")!)
            req.httpMethod = "PUT"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, _) = try await URLSession.shared.data(for: req)
            if let bio { profile?.bio = bio }
            if let location { profile?.location = location }
            lastLoadedAt = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Avatar upload

    func uploadAvatar(_ imageData: Data) async {
        guard let image = UIImage(data: imageData) else {
            error = "Invalid image data"; return
        }
        isUploadingAvatar = true
        error = nil
        do {
            let cdnUrl = try await UploadService.shared.uploadImage(image, type: .avatar)
            profile?.avatarUrl = cdnUrl
            lastLoadedAt = nil
        } catch {
            self.error = error.localizedDescription
        }
        isUploadingAvatar = false
    }

    // MARK: - Reverse geocode

    func reverseGeocodeCurrentLocation(_ location: CLLocation) async -> ProfileLocation? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return nil }
            return ProfileLocation(
                city: placemark.locality ?? placemark.administrativeArea,
                country: placemark.country
            )
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func parseProfile(_ json: [String: Any]) -> UserProfile {
        var loc: ProfileLocation?
        if let locJson = json["location"] as? [String: Any] {
            loc = ProfileLocation(
                city: locJson["city"] as? String,
                country: locJson["country"] as? String
            )
        }
        return UserProfile(
            userId: json["userId"] as? String ?? "",
            handle: json["handle"] as? String ?? "",
            name: json["name"] as? String,
            bio: json["bio"] as? String,
            avatarUrl: json["avatarUrl"] as? String,
            location: loc,
            createdAt: json["createdAt"] as? String,
            followersCount: json["followersCount"] as? Int ?? 0,
            followingCount: json["followingCount"] as? Int ?? 0
        )
    }

    private func parsePosts(_ raw: [[String: Any]]) -> [UserProfileData.UserProfilePost] {
        raw.compactMap { p in
            guard let postId = p["postId"] as? String,
                  let track = p["track"] as? [String: Any],
                  let title = track["title"] as? String,
                  let artist = track["artist"] as? String else { return nil }
            return UserProfileData.UserProfilePost(
                id: postId,
                track: .init(
                    title: title,
                    artist: artist,
                    album: track["album"] as? String,
                    artwork: track["artwork"] as? String,
                    appleMusicUrl: track["appleMusicUrl"] as? String
                ),
                comment: p["comment"] as? String,
                tags: p["tags"] as? [String] ?? [],
                createdAt: p["createdAt"] as? String ?? ""
            )
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

