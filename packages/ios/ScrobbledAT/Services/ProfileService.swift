import Foundation
import UIKit
import CoreLocation

@MainActor
class ProfileService: ObservableObject {
    static let shared = ProfileService()

    @Published var profile: UserProfile?
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
    }

    struct ProfileLocation: Codable {
        var city: String?
        var country: String?

        var displayString: String? {
            [city, country].compactMap { $0 }.joined(separator: ", ").nonEmpty
        }
    }

    private let apiBaseUrl = Config.apiBaseUrl

    // MARK: - Load own profile

    func loadMyProfile() async {
        guard let idToken = KeychainService.shared.get(key: "idToken") else { return }
        isLoading = true
        error = nil
        do {
            var req = URLRequest(url: URL(string: "\(apiBaseUrl)/me")!)
            req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            profile = parseProfile(json)
            // Keep PostHog person properties current
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
            // Update local state
            if let bio { profile?.bio = bio }
            if let location { profile?.location = location }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Avatar upload

    /// Resize, convert to WebP, upload via pre-signed URL, update local state.
    func uploadAvatar(_ imageData: Data) async {
        guard let image = UIImage(data: imageData) else {
            error = "Invalid image data"
            return
        }
        isUploadingAvatar = true
        error = nil
        do {
            let cdnUrl = try await UploadService.shared.uploadImage(image, type: .avatar)
            profile?.avatarUrl = cdnUrl
        } catch {
            self.error = error.localizedDescription
        }
        isUploadingAvatar = false
    }

    // MARK: - Reverse geocode location to city/country

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
            createdAt: json["createdAt"] as? String
        )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
