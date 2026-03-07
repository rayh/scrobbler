import SwiftUI

struct FeedView: View {
    @EnvironmentObject var feedService: FeedService
    @EnvironmentObject var appleSignInService: AppleSignInService
    @State private var hasLoaded = false
    
    var body: some View {
        NavigationView {
            VStack {
                if appleSignInService.isAuthenticated {
                    if feedService.posts.isEmpty && !feedService.isLoading {
                        emptyStateView
                    } else {
                        feedListView
                    }
                } else {
                    notAuthenticatedView
                }
            }
            .navigationTitle("Feed")
            .refreshable {
                await feedService.loadFeed(refresh: true)
            }
            .task {
                if appleSignInService.isAuthenticated && !hasLoaded {
                    await feedService.loadFeed(refresh: true)
                    hasLoaded = true
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No music shared yet")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("Follow some friends to see their music shares here")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
    
    private var feedListView: some View {
        List {
            ForEach(feedService.posts) { post in
                FeedPostCell(post: post)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
            
            if feedService.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(PlainListStyle())
    }
    
    private var notAuthenticatedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("Sign in to see your feed")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("Connect with friends and discover new music")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct FeedPostCell: View {
    let post: FeedService.FeedPost
    @EnvironmentObject var feedService: FeedService
    @State private var isLiked = false
    @State private var likeCount: Int
    @State private var isLiking = false

    init(post: FeedService.FeedPost) {
        self.post = post
        _likeCount = State(initialValue: post.likes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Hero artwork ──────────────────────────────────────────────
            ZStack(alignment: .bottomLeading) {
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
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipped()

                // Gradient so text is legible over any artwork
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(height: 220)

                // Track title + artist overlaid on artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.track.title)
                        .font(.title3).fontWeight(.bold)
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Text(post.track.artist)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                    if let album = post.track.album {
                        Text(album)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                .padding(12)
            }

            // ── Body ──────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {

                // Sharer row
                HStack(spacing: 10) {
                    NavigationLink(destination: UserProfileView(handle: post.userHandle)) {
                        Circle()
                            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(String(post.userName?.first ?? post.userHandle.first ?? "?").uppercased())
                                    .foregroundColor(.white)
                                    .fontWeight(.semibold)
                                    .font(.system(size: 15))
                            )
                    }
                    .buttonStyle(.plain)

                    NavigationLink(destination: UserProfileView(handle: post.userHandle)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(post.userName ?? post.userHandle)
                                .font(.subheadline).fontWeight(.semibold)
                                .foregroundColor(.primary)
                            Text("@\(post.userHandle)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text(timeAgo(from: post.createdAt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Comment
                if let comment = post.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.body)
                        .lineLimit(nil)
                }

                // Voice memo
                if let voiceMemoUrl = post.voiceMemoUrl, !voiceMemoUrl.isEmpty {
                    Label("Voice memo", systemImage: "waveform")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        // TODO: wire up audio player
                }

                // Tags
                if !post.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(post.tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.caption).fontWeight(.medium)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundColor(.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                // Action row
                HStack(spacing: 0) {

                    // Heart
                    Button {
                        guard !isLiking else { return }
                        // Optimistic update
                        isLiked.toggle()
                        likeCount += isLiked ? 1 : -1
                        isLiking = true
                        Task {
                            defer { isLiking = false }
                            let result = await feedService.likePost(postId: post.postId, postOwnerId: post.userId, isCurrentlyLiked: isLiked)
                            if let liked = result {
                                // Sync with server truth if it differs
                                if liked != isLiked {
                                    isLiked = liked
                                    likeCount += liked ? 1 : -1
                                }
                            } else {
                                // Revert optimistic update on failure
                                isLiked.toggle()
                                likeCount += isLiked ? 1 : -1
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isLiked ? "heart.fill" : "heart")
                                .foregroundColor(isLiked ? .red : .secondary)
                            if likeCount > 0 {
                                Text("\(likeCount)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Location
                    if let location = post.location {
                        Label(approxLocation(location), systemImage: "location.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.trailing, 12)
                    }

                    // Apple Music
                    if let urlString = post.track.appleMusicUrl, let url = URL(string: urlString) {
                        Link(destination: url) {
                            HStack(spacing: 5) {
                                Image(systemName: "apple.logo")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Apple Music")
                                    .font(.caption).fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(
                                LinearGradient(colors: [Color(red: 0.98, green: 0.2, blue: 0.4),
                                                        Color(red: 0.85, green: 0.1, blue: 0.2)],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color(.label).opacity(0.07), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 12)
    }

    private var artworkPlaceholder: some View {
        Rectangle()
            .fill(LinearGradient(colors: [Color(.systemGray4), Color(.systemGray5)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 48))
                    .foregroundColor(.white.opacity(0.6))
            )
    }

    private func timeAgo(from dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: dateString) else { return "" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }

    private func approxLocation(_ location: FeedService.FeedPost.LocationInfo) -> String {
        // Use reverse geocoding via CLGeocoder for a human-readable neighbourhood name.
        // For now return a formatted coordinate pair as a lightweight fallback;
        // a CLGeocoder call would require async context — wire up properly when building
        // a dedicated location detail view.
        let lat = location.latitude
        let lon = location.longitude
        let latDir = lat >= 0 ? "N" : "S"
        let lonDir = lon >= 0 ? "E" : "W"
        return String(format: "%.2f°%@ %.2f°%@", abs(lat), latDir, abs(lon), lonDir)
    }
}

// Keep RichFeedPostView as a typealias so any other references don't break
typealias RichFeedPostView = FeedPostCell
