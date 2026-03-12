import SwiftUI

@MainActor
class FeedService: ObservableObject {
    static let shared = FeedService()

    @Published var groups: [FeedGroup] = []
    @Published var isLoading = false
    @Published var error: String?

    // ── Models ────────────────────────────────────────────────────────────────

    struct FeedGroup: Identifiable {
        let id = UUID()
        let groupId: String
        let trackKey: String?
        let track: TrackInfo
        let windowStart: String
        let lastUpdatedAt: String
        let sharedBy: [SharedByEntry]
        let likes: Int
        let location: LocationInfo?

        struct TrackInfo {
            let id: String?
            let title: String
            let artist: String
            let album: String?
            let artwork: String?
            let appleMusicUrl: String?
            let spotifyUrl: String?
        }

        struct SharedByEntry {
            let postId: String
            let userId: String
            let userHandle: String
            let voiceMemoUrl: String?
            let transcript: String?
            let tags: [String]
            let createdAt: String
        }

        struct LocationInfo {
            let latitude: Double
            let longitude: Double
            let hex: String?
        }
    }

    // ── Networking ────────────────────────────────────────────────────────────

    private let apiBaseUrl = Config.apiBaseUrl

    private func makeAuthenticatedRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)

        if let idToken = KeychainService.shared.get(key: "idToken") {
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 {
                print("❌ Auth failed: 401 - logging out")
                await MainActor.run {
                    NotificationCenter.default.post(name: .forceLogout, object: nil)
                }
                throw URLError(.userAuthenticationRequired)
            } else if httpResponse.statusCode == 403 {
                print("❌ Request forbidden (403)")
                throw URLError(.userAuthenticationRequired)
            }
        }

        return data
    }

    // ── Feed loading ──────────────────────────────────────────────────────────

    func loadFeed(refresh: Bool = false) async {
        // Don't blank the list immediately on refresh — keep current content
        // visible until new data arrives (prevents flash of empty state).
        isLoading = true
        error = nil

        do {
            guard let url = URL(string: "\(apiBaseUrl)/feed/following") else {
                throw URLError(.badURL)
            }

            let data = try await makeAuthenticatedRequest(url: url)
            let response = try JSONDecoder().decode(FeedResponse.self, from: data)

            // Only populate mock data when there's nothing at all to show yet
            if response.groups.isEmpty && self.groups.isEmpty {
                self.loadMockData()
                self.isLoading = false
                return
            }

            self.groups = response.groups.map { g in
                FeedGroup(
                    groupId: g.groupId,
                    trackKey: g.trackKey,
                    track: FeedGroup.TrackInfo(
                        id: g.track.id,
                        title: g.track.title,
                        artist: g.track.artist,
                        album: g.track.album,
                        artwork: g.track.artwork,
                        appleMusicUrl: g.track.appleMusicUrl,
                        spotifyUrl: g.track.spotifyUrl
                    ),
                    windowStart: g.windowStart,
                    lastUpdatedAt: g.lastUpdatedAt,
                    sharedBy: g.sharedBy.map { s in
                        FeedGroup.SharedByEntry(
                            postId: s.postId,
                            userId: s.userId,
                            userHandle: s.userHandle,
                            voiceMemoUrl: s.voiceMemoUrl,
                            transcript: s.transcript,
                            tags: s.tags,
                            createdAt: s.createdAt
                        )
                    },
                    likes: g.likes ?? 0,
                    location: g.location.map {
                        FeedGroup.LocationInfo(latitude: $0.latitude, longitude: $0.longitude, hex: $0.hex)
                    }
                )
            }

        } catch {
            self.error = "Failed to load feed: \(error.localizedDescription)"
            self.loadMockData()
        }

        self.isLoading = false
    }

    // ── Like ──────────────────────────────────────────────────────────────────

    /// Toggle like on a group (keyed by the first entry's postId). Returns new liked state or nil on failure.
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

    // ── Mock data ─────────────────────────────────────────────────────────────

    private func loadMockData() {
        let now = Date()
        groups = [
            FeedGroup(
                groupId: "mock-group-1",
                trackKey: "blindinglights#theweeknd",
                track: FeedGroup.TrackInfo(
                    id: "track-001",
                    title: "Blinding Lights",
                    artist: "The Weeknd",
                    album: "After Hours",
                    artwork: "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/a6/6e/bf/a66ebf79-5008-8948-b352-a790fc87446b/19UM1IM04638.rgb.jpg/400x400bb.jpg",
                    appleMusicUrl: "https://music.apple.com/us/album/after-hours/1499378108?i=1499378112",
                    spotifyUrl: "https://open.spotify.com/track/0VjIjW4GlUZAMYd2vXMi3b"
                ),
                windowStart: ISO8601DateFormatter().string(from: now.addingTimeInterval(-7200)),
                lastUpdatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600)),
                sharedBy: [
                    FeedGroup.SharedByEntry(
                        postId: "mock-post-1",
                        userId: "user-ray-001",
                        userHandle: "ray",
                        voiceMemoUrl: nil,
                        transcript: "Perfect for late night coding",
                        tags: ["coding", "vibes"],
                        createdAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-7200))
                    ),
                    FeedGroup.SharedByEntry(
                        postId: "mock-post-2",
                        userId: "user-sarah-002",
                        userHandle: "sarahbeats",
                        voiceMemoUrl: nil,
                        transcript: "This one hits different at 2am",
                        tags: ["latenight"],
                        createdAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
                    )
                ],
                likes: 12,
                location: FeedGroup.LocationInfo(latitude: 51.5074, longitude: -0.1278, hex: "88be0e35cbfffff")
            ),
            FeedGroup(
                groupId: "mock-group-2",
                trackKey: "levitating#dualipa",
                track: FeedGroup.TrackInfo(
                    id: "track-002",
                    title: "Levitating",
                    artist: "Dua Lipa",
                    album: "Future Nostalgia",
                    artwork: "https://is1-ssl.mzstatic.com/image/thumb/Music116/v4/6c/11/d6/6c11d681-aa3a-d59e-4c2e-f77e181026ab/190295092665.jpg/400x400bb.jpg",
                    appleMusicUrl: "https://music.apple.com/us/album/future-nostalgia/1498378108?i=1498378115",
                    spotifyUrl: "https://open.spotify.com/track/463CkQjx2Zkim1kGkN7kGC"
                ),
                windowStart: ISO8601DateFormatter().string(from: now.addingTimeInterval(-14400)),
                lastUpdatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-14400)),
                sharedBy: [
                    FeedGroup.SharedByEntry(
                        postId: "mock-post-3",
                        userId: "user-mike-003",
                        userHandle: "mikevibes",
                        voiceMemoUrl: nil,
                        transcript: "The production on this is absolutely insane",
                        tags: ["dualipa", "production"],
                        createdAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-14400))
                    )
                ],
                likes: 5,
                location: nil
            )
        ]
    }

    // ── Codable response types ─────────────────────────────────────────────────

    private struct FeedResponse: Codable {
        let groups: [BackendGroup]
    }

    private struct BackendGroup: Codable {
        let groupId: String
        let trackKey: String?
        let track: BackendTrack
        let windowStart: String
        let lastUpdatedAt: String
        let sharedBy: [BackendSharedBy]
        let likes: Int?
        let location: BackendLocation?
    }

    private struct BackendTrack: Codable {
        let id: String?
        let title: String
        let artist: String
        let album: String?
        let artwork: String?
        let appleMusicUrl: String?
        let spotifyUrl: String?
    }

    private struct BackendSharedBy: Codable {
        let postId: String
        let userId: String
        let userHandle: String
        let voiceMemoUrl: String?
        let transcript: String?
        let tags: [String]
        let createdAt: String
    }

    private struct BackendLocation: Codable {
        let latitude: Double
        let longitude: Double
        let hex: String?
    }
}

// Keep old typealias so any remaining references to FeedService.FeedPost compile
// during migration — maps to FeedGroup for now
typealias FeedPost = FeedService.FeedGroup
