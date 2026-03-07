import SwiftUI

// MARK: - Data model

struct UserProfileData {
    var userId: String
    var handle: String
    var name: String?
    var bio: String?
    var avatarUrl: String?
    var locationCity: String?
    var locationCountry: String?
    var createdAt: String?
    var posts: [UserProfilePost]

    var locationDisplay: String? {
        [locationCity, locationCountry].compactMap { $0 }.joined(separator: ", ").nonEmpty
    }

    struct UserProfilePost: Identifiable {
        let id: String  // postId
        let track: TrackInfo
        let comment: String?
        let tags: [String]
        let createdAt: String

        struct TrackInfo {
            let title: String
            let artist: String
            let album: String?
            let artwork: String?
            let appleMusicUrl: String?
        }
    }
}

// MARK: - View model

@MainActor
class UserProfileViewModel: ObservableObject {
    @Published var profileData: UserProfileData?
    @Published var isLoading = false
    @Published var isFollowLoading = false
    @Published var error: String?

    private let apiBaseUrl = Config.apiBaseUrl

    func load(handle: String) async {
        isLoading = true
        error = nil
        do {
            guard let url = URL(string: "\(apiBaseUrl)/users/\(handle.lowercased())") else { return }
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 404 {
                error = "User not found"
                isLoading = false
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            profileData = parseProfile(json)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func toggleFollow(handle: String) async {
        let socialService = SocialService.shared
        isFollowLoading = true
        if socialService.isFollowing(handle: handle) {
            await socialService.unfollow(handle: handle)
        } else {
            await socialService.follow(handle: handle)
        }
        isFollowLoading = false
        // Reload following list so isFollowing reflects truth
        await socialService.loadFollowing()
    }

    private func parseProfile(_ json: [String: Any]) -> UserProfileData {
        var city: String?
        var country: String?
        if let loc = json["location"] as? [String: Any] {
            city = loc["city"] as? String
            country = loc["country"] as? String
        }

        let rawPosts = json["posts"] as? [[String: Any]] ?? []
        let posts: [UserProfileData.UserProfilePost] = rawPosts.compactMap { p in
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

        return UserProfileData(
            userId: json["userId"] as? String ?? "",
            handle: json["handle"] as? String ?? "",
            name: json["name"] as? String,
            bio: json["bio"] as? String,
            avatarUrl: json["avatarUrl"] as? String,
            locationCity: city,
            locationCountry: country,
            createdAt: json["createdAt"] as? String,
            posts: posts
        )
    }
}

// MARK: - Main View

struct UserProfileView: View {
    let handle: String
    var isModal: Bool = false          // true when presented as sheet (e.g. invite deep link)
    var onDismiss: (() -> Void)? = nil

    @StateObject private var vm = UserProfileViewModel()
    @ObservedObject private var socialService = SocialService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if vm.isLoading && vm.profileData == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = vm.error {
                VStack(spacing: 12) {
                    Image(systemName: "person.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(err)
                        .foregroundColor(.secondary)
                    Button("Retry") { Task { await vm.load(handle: handle) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let profile = vm.profileData {
                profileContent(profile)
            } else {
                // Initial state before .task fires — show spinner immediately
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("@\(handle)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let social = socialService
            let model = vm
            async let followingLoad: () = social.loadFollowingIfNeeded()
            async let profileLoad: () = model.load(handle: handle)
            _ = await (followingLoad, profileLoad)
        }
        .refreshable {
            await vm.load(handle: handle)
        }
    }

    @ViewBuilder
    private func profileContent(_ profile: UserProfileData) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                profileHeader(profile)
                    .padding()

                Divider()

                if profile.posts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No shares yet")
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 48)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(profile.posts) { post in
                            postCard(post)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    @ViewBuilder
    private func profileHeader(_ profile: UserProfileData) -> some View {
        VStack(spacing: 16) {
            // Avatar
            Group {
                if let avatarUrl = profile.avatarUrl, let url = URL(string: avatarUrl) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        avatarPlaceholder(profile)
                    }
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                } else {
                    avatarPlaceholder(profile)
                }
            }

            // Name + handle
            VStack(spacing: 4) {
                if let name = profile.name, !name.isEmpty {
                    Text(name)
                        .font(.title3)
                        .fontWeight(.bold)
                }
                Text("@\(profile.handle)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Location
            if let loc = profile.locationDisplay {
                Label(loc, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Bio
            if let bio = profile.bio, !bio.isEmpty {
                Text(bio)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.primary)
            }

            // Follow / Unfollow — only show when authenticated and not viewing own profile
            if socialService.isAuthenticated {
                let following = socialService.isFollowing(handle: profile.handle)
                Button {
                    Task { await vm.toggleFollow(handle: profile.handle) }
                } label: {
                    if vm.isFollowLoading {
                        ProgressView()
                            .frame(minWidth: 120)
                    } else {
                        Text(following ? "Unfollow" : "Follow")
                            .fontWeight(.medium)
                            .frame(minWidth: 120)
                    }
                }
                .buttonStyle(.bordered)
                .tint(following ? .red : .blue)
                .disabled(vm.isFollowLoading)
            }
        }
    }

    @ViewBuilder
    private func avatarPlaceholder(_ profile: UserProfileData) -> some View {
        Circle()
            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 80, height: 80)
            .overlay(
                Text(String(profile.name?.first ?? profile.handle.first ?? "?").uppercased())
                    .foregroundColor(.white)
                    .font(.title)
                    .fontWeight(.medium)
            )
    }

    @ViewBuilder
    private func postCard(_ post: UserProfileData.UserProfilePost) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                // Album art
                Group {
                    if let artwork = post.track.artwork, let url = URL(string: artwork) {
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            artworkPlaceholder
                        }
                    } else {
                        artworkPlaceholder
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)

                // Track info
                VStack(alignment: .leading, spacing: 3) {
                    Text(post.track.title)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                    Text(post.track.artist)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if let album = post.track.album {
                        Text(album)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(timeAgo(from: post.createdAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)

                // Apple Music link
                if let appleUrl = post.track.appleMusicUrl, let url = URL(string: appleUrl) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Comment
            if let comment = post.comment, !comment.isEmpty {
                Text(comment)
                    .font(.body)
                    .lineLimit(nil)
            }

            // Tags
            if !post.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(post.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.001).background(.background))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.07), radius: 6, x: 0, y: 2)
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 28))
                    .foregroundColor(.gray)
            )
    }

    private func timeAgo(from dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: dateString) else { return "" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
