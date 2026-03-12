import SwiftUI
import MusicKit

@MainActor
class MusicService: ObservableObject {
    static let shared = MusicService()

    @Published var authorizationStatus: MusicAuthorization.Status = .notDetermined
    @Published var isLoading = false
    @Published var error: String?
    
    private let apiBaseUrl = "https://PLACEHOLDER_API_GATEWAY_URL" // Update after deployment
    
    init() {
        authorizationStatus = MusicAuthorization.currentStatus
    }
    
    func requestMusicAuthorization() async {
        let status = await MusicAuthorization.request()
        authorizationStatus = status
    }
    
    func shareTrack(_ track: Track, comment: String = "", tags: [String] = []) async {
        guard authorizationStatus == .authorized else {
            error = "Music access not authorized"
            return
        }

        isLoading = true
        error = nil

        do {
            let trackData: [String: Any] = [
                "id": track.id,
                "title": track.title,
                "artist": track.artist,
                "album": track.album ?? "",
                "artwork": track.artworkUrl ?? "",
                "appleMusicUrl": track.appleMusicUrl ?? ""
            ]

            let requestBody: [String: Any] = [
                "track": trackData,
                "comment": comment,
                "tags": tags
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
            
            var request = URLRequest(url: URL(string: "\(apiBaseUrl)/music/share")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            // Add Cognito credentials for authorization
            if let cognitoIdentityId = UserDefaults.standard.string(forKey: "cognitoIdentityId") {
                request.setValue("Bearer \(cognitoIdentityId)", forHTTPHeaderField: "Authorization")
            }
            
            request.httpBody = jsonData
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "NetworkError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }
            
            if httpResponse.statusCode == 200 {
                // Success - track shared
                NotificationCenter.default.post(name: .trackShared, object: nil)
            } else {
                let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let errorMessage = errorData?["error"] as? String ?? "Failed to share track"
                throw NSError(domain: "APIError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
            
        } catch {
            self.error = "Failed to share track: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    func searchSongs(query: String) async -> [Song] {
        guard authorizationStatus == .authorized else { return [] }
        do {
            var searchRequest = MusicCatalogSearchRequest(term: query, types: [Song.self])
            searchRequest.limit = 20
            let searchResponse = try await searchRequest.response()
            return Array(searchResponse.songs)
        } catch {
            self.error = "Search failed: \(error.localizedDescription)"
            return []
        }
    }

    func getRecentlyPlayedSongs() async -> [Song] {
        guard authorizationStatus == .authorized else { return [] }
        do {
            let request = MusicRecentlyPlayedRequest<Song>()
            let response = try await request.response()
            return Array(response.items)
        } catch {
            self.error = "Failed to get recently played: \(error.localizedDescription)"
            return []
        }
    }

    // Searches the Apple Music catalog. Returns MusicKit Song objects.
    func searchTracks(query: String) async -> [Song] {
        guard authorizationStatus == .authorized else { return [] }
        do {
            var searchRequest = MusicCatalogSearchRequest(term: query, types: [Song.self])
            searchRequest.limit = 20
            let searchResponse = try await searchRequest.response()
            return Array(searchResponse.songs)
        } catch {
            self.error = "Search failed: \(error.localizedDescription)"
            return []
        }
    }

    func getRecentlyPlayed() async -> [Song] {
        guard authorizationStatus == .authorized else { return [] }
        do {
            let request = MusicRecentlyPlayedRequest<Song>()
            let response = try await request.response()
            return Array(response.items)
        } catch {
            self.error = "Failed to get recently played: \(error.localizedDescription)"
            return []
        }
    }
}

extension Notification.Name {
    static let trackShared = Notification.Name("trackShared")
}
