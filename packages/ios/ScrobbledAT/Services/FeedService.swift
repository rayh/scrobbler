import SwiftUI

@MainActor
class FeedService: ObservableObject {
    @Published var posts: [FeedPost] = []
    @Published var isLoading = false
    @Published var error: String?
    
    struct FeedPost: Identifiable {
        let id = UUID()
        let postId: String
        let userId: String
        let userHandle: String
        let userName: String?
        let track: TrackInfo
        let comment: String?
        let voiceMemoUrl: String?
        let tags: [String]
        let createdAt: String
        let likes: Int
        let location: LocationInfo?

        struct TrackInfo {
            let id: String
            let title: String
            let artist: String
            let album: String?
            let artwork: String?
            let appleMusicUrl: String?
        }

        struct LocationInfo {
            let latitude: Double
            let longitude: Double
            let hex: String?
        }
    }
    
    private let apiBaseUrl = Config.apiBaseUrl
    
    private func makeAuthenticatedRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        
        if let idToken = KeychainService.shared.get(key: "idToken") {
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            // 401 = token expired/invalid → force logout so user re-authenticates.
            // 403 = forbidden (missing token, wrong scope, etc.) → don't logout; surface as an error.
            //       API Gateway JWT authorizer returns 403, not 401, for missing/malformed tokens.
            if httpResponse.statusCode == 401 {
                print("❌ Auth failed: 401 - logging out")
                await MainActor.run {
                    NotificationCenter.default.post(name: .forceLogout, object: nil)
                }
                throw URLError(.userAuthenticationRequired)
            } else if httpResponse.statusCode == 403 {
                print("❌ Request forbidden (403) - not logging out")
                throw URLError(.userAuthenticationRequired)
            }
        }
        
        return data
    }
    
    func loadFeed(refresh: Bool = false) async {
        if refresh {
            posts = []
        }
        
        isLoading = true
        error = nil
        
        do {
            guard let url = URL(string: "\(apiBaseUrl)/feed/following") else {
                throw URLError(.badURL)
            }
            
            let data = try await makeAuthenticatedRequest(url: url)
            let feedResponse = try JSONDecoder().decode(FeedResponse.self, from: data)
            
            await MainActor.run {
                self.posts = feedResponse.posts.map { backendPost in
                    FeedPost(
                        postId: backendPost.postId,
                        userId: backendPost.userId,
                        userHandle: backendPost.userHandle,
                        userName: backendPost.userName,
                        track: FeedPost.TrackInfo(
                            id: backendPost.track.id,
                            title: backendPost.track.title,
                            artist: backendPost.track.artist,
                            album: backendPost.track.album,
                            artwork: backendPost.track.artwork,
                            appleMusicUrl: backendPost.track.appleMusicUrl
                        ),
                        comment: backendPost.comment,
                        voiceMemoUrl: backendPost.voiceMemoUrl,
                        tags: backendPost.tags,
                        createdAt: backendPost.createdAt,
                        likes: backendPost.likes ?? 0,
                        location: backendPost.location.map {
                            FeedPost.LocationInfo(latitude: $0.latitude, longitude: $0.longitude, hex: $0.hex)
                        }
                    )
                }
            }
            
        } catch {
            await MainActor.run {
                self.error = "Failed to load feed: \(error.localizedDescription)"
                // Fallback to mock data for now
                self.loadMockData()
            }
        }
        
        await MainActor.run {
            self.isLoading = false
        }
    }
    
    private func loadMockData() {
        posts = [
            FeedPost(
                postId: "mock-1",
                userId: "user-ray-001",
                userHandle: "ray",
                userName: "Ray Hilton",
                track: FeedPost.TrackInfo(
                    id: "track-001",
                    title: "Blinding Lights",
                    artist: "The Weeknd",
                    album: "After Hours",
                    artwork: "https://i.scdn.co/image/ab67616d0000b273ef6f049cce6fdc2e1c65c8b5",
                    appleMusicUrl: "https://music.apple.com/us/album/after-hours/1499378108?i=1499378112"
                ),
                comment: "Perfect for late night coding! 💻",
                voiceMemoUrl: nil,
                tags: ["coding", "vibes"],
                createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200)),
                likes: 12,
                location: FeedPost.LocationInfo(latitude: 51.5074, longitude: -0.1278, hex: "88be0e35cbfffff")
            ),
            FeedPost(
                postId: "mock-2",
                userId: "user-sarah-002",
                userHandle: "sarahbeats",
                userName: "Sarah Chen",
                track: FeedPost.TrackInfo(
                    id: "track-002",
                    title: "Levitating",
                    artist: "Dua Lipa",
                    album: "Future Nostalgia",
                    artwork: "https://i.scdn.co/image/ab67616d0000b273c9b6207039d9c2e4b5b8c2e4",
                    appleMusicUrl: "https://music.apple.com/us/album/future-nostalgia/1498378108?i=1498378115"
                ),
                comment: "The production on this is absolutely insane! 🔥",
                voiceMemoUrl: nil,
                tags: ["dualipa", "production"],
                createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-14400)),
                likes: 5,
                location: nil
            ),
            FeedPost(
                postId: "mock-3",
                userId: "user-mike-003",
                userHandle: "mikevibes",
                userName: "Mike Rodriguez",
                track: FeedPost.TrackInfo(
                    id: "track-003",
                    title: "Good 4 U",
                    artist: "Olivia Rodrigo",
                    album: "SOUR",
                    artwork: "https://i.scdn.co/image/ab67616d0000b273a91c10fe9472d9bd89802e5a",
                    appleMusicUrl: "https://music.apple.com/us/album/sour/1567714688?i=1567714698"
                ),
                comment: "Olivia's songwriting is next level 🎵",
                voiceMemoUrl: nil,
                tags: ["oliviarodrigo", "songwriting"],
                createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-21600)),
                likes: 0,
                location: nil
            )
        ]
    }
    
    // Backend response models
    struct FeedResponse: Codable {
        let posts: [BackendPost]
    }
    
    struct BackendPost: Codable {
        let postId: String
        let userId: String
        let userHandle: String
        let userName: String?
        let track: BackendTrack
        let comment: String?
        let voiceMemoUrl: String?
        let tags: [String]
        let createdAt: String
        let likes: Int?
        let location: BackendLocation?
    }

    struct BackendTrack: Codable {
        let id: String
        let title: String
        let artist: String
        let album: String?
        let artwork: String?
        let appleMusicUrl: String?
    }

    struct BackendLocation: Codable {
        let latitude: Double
        let longitude: Double
        let hex: String?
    }
    
    /// Toggle like on a post. Returns the new liked state, or nil on failure.
    func likePost(postId: String, postOwnerId: String, isCurrentlyLiked: Bool) async -> Bool? {
        guard let url = URL(string: "\(apiBaseUrl)/music/like") else { return nil }
        guard let idToken = KeychainService.shared.get(key: "idToken") else { return nil }

        let action = isCurrentlyLiked ? "unlike" : "like"
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "postId": postId,
                "postOwnerId": postOwnerId,
                "action": action
            ])

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let liked = action == "like"
            if liked {
                Analytics.like(postId: postId, ownerHandle: postOwnerId)
            } else {
                Analytics.unlike(postId: postId, ownerHandle: postOwnerId)
            }
            return liked
        } catch {
            Analytics.error("Like/unlike failed", context: "FeedService.likePost", underlyingError: error)
            print("❌ Like failed: \(error)")
            return nil
        }
    }

    func followUser(_ handle: String) async {
        // Simulate API call
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    
    func unfollowUser(_ handle: String) async {
        // Simulate API call
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    
    func addMockPost(track: FeedPost.TrackInfo, comment: String?, tags: [String]) {
        let newPost = FeedPost(
            postId: "post-\(Date().timeIntervalSince1970)",
            userId: "dev-user-123",
            userHandle: "devuser",
            userName: "Dev User",
            track: track,
            comment: comment,
            voiceMemoUrl: nil,
            tags: tags,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            likes: 0,
            location: nil
        )
        posts.insert(newPost, at: 0)
    }
}
