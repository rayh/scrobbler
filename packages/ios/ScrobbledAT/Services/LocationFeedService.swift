import Foundation
import CoreLocation

@MainActor
class LocationFeedService: ObservableObject {
    static let shared = LocationFeedService()

    @Published var nearbyPosts: [LocationPost] = []
    @Published var isLoading = false
    @Published var error: String?
    
    private let apiBaseUrl = Config.apiBaseUrl
    
    struct LocationPost: Identifiable, Codable {
        let id = UUID()
        let postId: String
        let userId: String
        let userHandle: String
        let userName: String?
        let track: TrackInfo
        let comment: String?
        let tags: [String]
        let createdAt: String
        let location: LocationInfo?
        let nearby: Bool
        
        struct TrackInfo: Codable {
            let id: String
            let title: String
            let artist: String
            let album: String?
            let artwork: String?
            let appleMusicUrl: String?
        }
        
        struct LocationInfo: Codable {
            let latitude: Double
            let longitude: Double
            let hex: String
            let resolution: Int
        }
    }
    
    func loadNearbyPosts(location: CLLocation) async {
        guard !isLoading else {
            print("⏭️ LocationFeedService: loadNearbyPosts — already in flight, skipping")
            return
        }
        isLoading = true
        error = nil
        
        do {
            let lat = location.coordinate.latitude
            let lng = location.coordinate.longitude
            
            guard let url = URL(string: "\(apiBaseUrl)/location/feed?latitude=\(lat)&longitude=\(lng)") else {
                throw URLError(.badURL)
            }
            
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(LocationFeedResponse.self, from: data)
            
            self.nearbyPosts = response.posts.map { post in
                LocationPost(
                    postId: post.postId,
                    userId: post.userId,
                    userHandle: post.userHandle,
                    userName: post.userName,
                    track: LocationPost.TrackInfo(
                        id: post.track.id,
                        title: post.track.title,
                        artist: post.track.artist,
                        album: post.track.album,
                        artwork: post.track.artwork,
                        appleMusicUrl: post.track.appleMusicUrl
                    ),
                    comment: post.comment,
                    tags: post.tags,
                    createdAt: post.createdAt,
                    location: post.location.map { loc in
                        LocationPost.LocationInfo(
                            latitude: loc.latitude,
                            longitude: loc.longitude,
                            hex: loc.hex,
                            resolution: loc.resolution
                        )
                    },
                    nearby: post.nearby
                )
            }
            
        } catch {
            self.error = "Failed to load nearby posts: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    private struct LocationFeedResponse: Codable {
        let posts: [BackendLocationPost]
        let locationHex: String
        let hexBoundary: [[Double]]
    }
    
    private struct BackendLocationPost: Codable {
        let postId: String
        let userId: String
        let userHandle: String
        let userName: String?
        let track: BackendTrack
        let comment: String?
        let tags: [String]
        let createdAt: String
        let location: BackendLocation?
        let nearby: Bool
    }
    
    private struct BackendTrack: Codable {
        let id: String
        let title: String
        let artist: String
        let album: String?
        let artwork: String?
        let appleMusicUrl: String?
    }
    
    private struct BackendLocation: Codable {
        let latitude: Double
        let longitude: Double
        let hex: String
        let resolution: Int
    }
}
