import SwiftUI

struct FeedView: View {
    @EnvironmentObject var feedService: FeedService
    @EnvironmentObject var appleSignInService: AppleSignInService
    @State private var hasLoaded = false

    var body: some View {
        NavigationView {
            VStack {
                if appleSignInService.isAuthenticated {
                    if feedService.groups.isEmpty && !feedService.isLoading {
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
                Task { await MusicSyncService.shared.syncFeedPlaylist() }
            }
            .task {
                if appleSignInService.isAuthenticated && !hasLoaded {
                    await feedService.loadFeed(refresh: true)
                    hasLoaded = true
                    Task { await MusicSyncService.shared.syncFeedPlaylist() }
                }
            }
        }
    }

    private var feedListView: some View {
        List {
            ForEach(feedService.groups) { group in
                FeedPostCell(group: group)
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

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("No music shared yet")
                .font(.title2).fontWeight(.medium)
            Text("Follow some friends to see their music shares here")
                .font(.body).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var notAuthenticatedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("Sign in to see your feed")
                .font(.title2).fontWeight(.medium)
            Text("Connect with friends and discover new music")
                .font(.body).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - FeedPostCell

struct FeedPostCell: View {
    let group: FeedService.FeedGroup
    var showUser: Bool = true

    @EnvironmentObject var feedService: FeedService
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var appleSignInService: AppleSignInService
    @State private var isLiked = false
    @State private var likeCount: Int
    @State private var isLiking = false
    @State private var navigateToHandle: String? = nil
    @State private var showMusicAppPicker = false
    @State private var showRepostConfirmation = false

    init(group: FeedService.FeedGroup, showUser: Bool = true) {
        self.group = group
        self.showUser = showUser
        _likeCount = State(initialValue: group.likes)
    }

    private var primarySharer: FeedService.FeedGroup.SharedByEntry? {
        group.sharedBy.first
    }

    // Returns the URLs available for the track (non-nil), in preference order.
    private var availableMusicApps: [(AppSettings.MusicApp, URL)] {
        var result: [(AppSettings.MusicApp, URL)] = []
        if let raw = group.track.appleMusicUrl, let url = URL(string: raw) {
            result.append((.appleMusic, url))
        }
        if let raw = group.track.spotifyUrl, let url = URL(string: raw) {
            result.append((.spotify, url))
        }
        return result
    }

    private func openInMusicApp(_ app: AppSettings.MusicApp) {
        let pair = availableMusicApps.first { $0.0 == app } ?? availableMusicApps.first
        guard let (_, url) = pair else { return }
        UIApplication.shared.open(url)
    }

    private func handleCardTap() {
        let apps = availableMusicApps
        guard !apps.isEmpty else { return }

        if appSettings.hasSetMusicApp || apps.count == 1 {
            // Single app available or user already chose — open directly.
            openInMusicApp(appSettings.preferredMusicApp)
        } else {
            // Multiple apps, first time — show picker.
            showMusicAppPicker = true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Hero: artwork with avatar overlay ─────────────────────────
            ZStack(alignment: .topLeading) {
                // Artwork — tappable to open music app
                Button(action: handleCardTap) {
                    Group {
                        if let artwork = group.track.artwork, let url = URL(string: artwork) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().aspectRatio(contentMode: .fill)
                                default:
                                    artworkPlaceholder
                                }
                            }
                        } else {
                            artworkPlaceholder
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipped()
                }
                .buttonStyle(.plain)

                // Track info gradient overlay at bottom
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 100)
                }
                .frame(height: 220)

                // Track title/artist over gradient
                VStack(alignment: .leading, spacing: 2) {
                    Spacer()
                    Text(group.track.title)
                        .font(.title3).fontWeight(.bold)
                        .foregroundColor(.white).lineLimit(2)
                    Text(group.track.artist)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85)).lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: 220, alignment: .bottomLeading)

                // Avatar(s) — top-left corner
                if showUser {
                    avatarOverlay
                        .padding(10)
                }
            }

            // ── Comment + action row ───────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                commentRows
                actionRow
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color(.label).opacity(0.07), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 12)
        .background(
            Group {
                if let handle = navigateToHandle {
                    NavigationLink(
                        destination: UserProfileView(handle: handle),
                        isActive: Binding(
                            get: { navigateToHandle != nil },
                            set: { if !$0 { navigateToHandle = nil } }
                        )
                    ) { EmptyView() }
                    .hidden()
                }
            }
        )
        .confirmationDialog("Open in...", isPresented: $showMusicAppPicker, titleVisibility: .visible) {
            ForEach(availableMusicApps, id: \.0) { app, url in
                Button(app.displayName) {
                    appSettings.preferredMusicApp = app
                    appSettings.hasSetMusicApp = true
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose your preferred music app. You can change this in Settings.")
        }
    }

    // MARK: - Avatar overlay (top-left of image)

    @ViewBuilder
    private var avatarOverlay: some View {
        if group.sharedBy.count == 1, let sharer = primarySharer {
            Button {
                navigateToHandle = sharer.userHandle
            } label: {
                avatarCircle(handle: sharer.userHandle, size: 38)
                    .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
        } else if group.sharedBy.count > 1 {
            // Stacked avatars (up to 3)
            HStack(spacing: -10) {
                ForEach(0..<min(3, group.sharedBy.count), id: \.self) { idx in
                    avatarCircle(handle: group.sharedBy[idx].userHandle, size: 34)
                        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                        .zIndex(Double(3 - idx))
                }
            }
        }
    }

    // MARK: - Comment rows (@handle: transcript per sharer)

    @ViewBuilder
    private var commentRows: some View {
        ForEach(group.sharedBy.indices, id: \.self) { idx in
            let entry = group.sharedBy[idx]
            HStack(alignment: .top, spacing: 0) {
                Button {
                    navigateToHandle = entry.userHandle
                } label: {
                    Text("@\(entry.userHandle)")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)

                if let transcript = entry.transcript, !transcript.isEmpty {
                    Text(": \(transcript)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                } else if entry.voiceMemoUrl != nil {
                    HStack(spacing: 4) {
                        Text(":")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Image(systemName: "waveform")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                        Text("voice intro")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Action row (heart + repost + time)

    /// True when the current user has already shared this track (hide repost).
    private var isOwnPost: Bool {
        guard let myHandle = appleSignInService.currentUser?.handle else { return false }
        return group.sharedBy.contains { $0.userHandle == myHandle }
    }

    private var actionRow: some View {
        HStack(spacing: 16) {
            // Like button
            Button {
                guard !isLiking, let postId = primarySharer?.postId,
                      let ownerId = primarySharer?.userId else { return }
                isLiked.toggle()
                likeCount += isLiked ? 1 : -1
                isLiking = true
                Task {
                    defer { isLiking = false }
                    let result = await feedService.likePost(
                        postId: postId,
                        postOwnerId: ownerId,
                        isCurrentlyLiked: isLiked
                    )
                    if let liked = result {
                        if liked != isLiked {
                            isLiked = liked
                            likeCount += liked ? 1 : -1
                        }
                    } else {
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
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                }
                .frame(minWidth: 44, minHeight: 36)
            }
            .buttonStyle(.plain)

            // Repost button — hidden on own posts
            if !isOwnPost {
                Button {
                    showRepostConfirmation = true
                } label: {
                    Image(systemName: "arrow.2.squarepath")
                        .foregroundColor(.secondary)
                        .frame(minWidth: 44, minHeight: 36)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Relative time — use lastUpdatedAt for groups, createdAt for single
            let timeString: String = {
                if group.sharedBy.count == 1, let sharer = primarySharer {
                    return timeAgo(from: sharer.createdAt)
                }
                return timeAgo(from: group.lastUpdatedAt)
            }()
            if !timeString.isEmpty {
                Text(timeString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .confirmationDialog("Repost", isPresented: $showRepostConfirmation, titleVisibility: .visible) {
            Button("Repost Now") {
                // TODO: call repost API
            }
            Button("Repost with Voice Note") {
                // TODO: open voice note recording modal
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Share \"\(group.track.title)\" with your followers.")
        }
    }

    // MARK: - Helpers

    private func avatarCircle(handle: String, size: CGFloat = 36) -> some View {
        Circle()
            .fill(LinearGradient(colors: [.blue, .purple],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Text(String(handle.first ?? "?").uppercased())
                    .foregroundColor(.white)
                    .fontWeight(.semibold)
                    .font(.system(size: size * 0.42))
            )
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
}

// Keep typealias so any remaining references compile
typealias RichFeedPostView = FeedPostCell
