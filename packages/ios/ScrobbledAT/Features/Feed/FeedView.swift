import SwiftUI
import AVFoundation

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
    /// When true, the like and repost buttons are hidden regardless of ownership.
    /// Use this when rendering in a profile context where actions don't make sense.
    var hideActions: Bool = false

    @EnvironmentObject var feedService: FeedService
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var appleSignInService: AppleSignInService
    @State private var isLiked = false
    @State private var likeCount: Int
    @State private var isLiking = false
    @State private var isReposted = false
    @State private var isReposting = false
    @State private var navigateToHandle: String? = nil
    @State private var showMusicAppPicker = false
    @State private var showRepostConfirmation = false
    @State private var showRepostVoiceSheet = false

    init(group: FeedService.FeedGroup, showUser: Bool = true, hideActions: Bool = false) {
        self.group = group
        self.showUser = showUser
        self.hideActions = hideActions
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

    /// True when the current user is the OG author (first sharer) — hide like + repost.
    /// Reposters are NOT considered own posts: they still need the button to undo the repost.
    private var isOwnPost: Bool {
        guard let myHandle = appleSignInService.currentUser?.handle else { return false }
        return group.sharedBy.first?.userHandle == myHandle
    }

    /// True when actions should be hidden — either forced by caller or this is an own post.
    private var shouldHideActions: Bool { hideActions || isOwnPost }

    private var actionRow: some View {
        HStack(spacing: 16) {
            if !shouldHideActions {
                // Like button
                Button {
                    guard !isLiking, let postId = primarySharer?.postId,
                          let ownerId = primarySharer?.userId else { return }
                    // Capture pre-toggle state before flipping
                    let wasLiked = isLiked
                    isLiked.toggle()
                    likeCount += isLiked ? 1 : -1
                    isLiking = true
                    Task {
                        defer { isLiking = false }
                        // Pass the PRE-toggle state so the service sends the right action
                        let result = await feedService.likePost(
                            postId: postId,
                            postOwnerId: ownerId,
                            isCurrentlyLiked: wasLiked
                        )
                        if let liked = result {
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
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 36)
                }
                .buttonStyle(.plain)

                // Repost button — highlighted when reposted, tapping again undoes it
                Button {
                    if isReposted {
                        // Undo repost — directly delete without confirmation
                        guard !isReposting, let postId = primarySharer?.postId else { return }
                        isReposted = false
                        isReposting = true
                        Task {
                            defer { isReposting = false }
                            let ok = await feedService.deletePost(postId: postId)
                            if !ok { isReposted = true } // revert on failure
                        }
                    } else {
                        showRepostConfirmation = true
                    }
                } label: {
                    Image(systemName: isReposted ? "arrow.2.squarepath" : "arrow.2.squarepath")
                        .foregroundColor(isReposted ? .green : .secondary)
                        .frame(minWidth: 44, minHeight: 36)
                }
                .buttonStyle(.plain)
                .disabled(isReposting)
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
                guard !isReposting, let postId = primarySharer?.postId,
                      let ownerId = primarySharer?.userId else { return }
                isReposted = true
                isReposting = true
                Task {
                    defer { isReposting = false }
                    let ok = await feedService.repost(
                        postId: postId,
                        postOwnerId: ownerId,
                        trackKey: group.trackKey ?? "",
                        track: group.track
                    )
                    if !ok { isReposted = false }
                }
            }
            Button("Repost with Voice Note") {
                showRepostVoiceSheet = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Share \"\(group.track.title)\" with your followers.")
        }
        .sheet(isPresented: $showRepostVoiceSheet) {
            RepostVoiceNoteView(group: group) { voiceMemoData, transcript in
                guard let postId = primarySharer?.postId,
                      let ownerId = primarySharer?.userId else { return }
                isReposted = true
                isReposting = true
                Task {
                    defer { isReposting = false }
                    let ok = await feedService.repost(
                        postId: postId,
                        postOwnerId: ownerId,
                        trackKey: group.trackKey ?? "",
                        track: group.track,
                        voiceMemoData: voiceMemoData,
                        transcript: transcript
                    )
                    if !ok { isReposted = false }
                }
            }
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
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: dateString)
            ?? ISO8601DateFormatter().date(from: dateString) // fallback without fractional seconds
        guard let date else { return "" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

// Keep typealias so any remaining references compile
typealias RichFeedPostView = FeedPostCell

// MARK: - RepostVoiceNoteView

/// Lightweight voice-note recorder modal for reposting with a voice intro.
struct RepostVoiceNoteView: View {
    let group: FeedService.FeedGroup
    let onComplete: (Data?, String?) -> Void

    @StateObject private var recorder = VoiceMemoRecorder()
    @State private var isPlayingBack = false
    @State private var audioPlayer: AVAudioPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {

                    // Track info
                    HStack(spacing: 14) {
                        Group {
                            if let artwork = group.track.artwork, let url = URL(string: artwork) {
                                AsyncImage(url: url) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Color(.systemGray5)
                                    }
                                }
                            } else {
                                Color(.systemGray5)
                                    .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.track.title).font(.headline).lineLimit(1)
                            Text(group.track.artist).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Divider()

                    // Recorder
                    VStack(spacing: 16) {
                        Text("Add a voice intro")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)

                        if recorder.recordedData == nil {
                            VStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(recorder.isRecording ? Color.red : Color.accentColor)
                                        .frame(width: 80, height: 80)
                                        .scaleEffect(recorder.isRecording ? 1.15 : 1.0)
                                        .animation(.easeInOut(duration: 0.15), value: recorder.isRecording)
                                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(.white)
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { _ in
                                            if !recorder.isRecording { recorder.startRecording() }
                                        }
                                        .onEnded { _ in
                                            if recorder.isRecording { recorder.stopRecording() }
                                        }
                                )

                                if recorder.isRecording {
                                    HStack(spacing: 6) {
                                        Image(systemName: "waveform")
                                            .foregroundColor(.red)
                                            .symbolEffect(.pulse)
                                        Text("Recording… release to stop (10s max)")
                                            .font(.caption).foregroundColor(.red)
                                    }
                                } else {
                                    Text("Hold to record · 10 seconds max")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal)

                        } else {
                            // Recorded state
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    Text("Intro recorded").font(.subheadline).fontWeight(.medium)
                                    Spacer()
                                    Button {
                                        audioPlayer?.stop(); audioPlayer = nil
                                        isPlayingBack = false
                                        recorder.clearRecording()
                                    } label: {
                                        Image(systemName: "trash").foregroundColor(.red)
                                    }
                                }
                                if !recorder.transcript.isEmpty {
                                    Text("\"\(recorder.transcript)\"")
                                        .font(.footnote).foregroundColor(.secondary).italic().lineLimit(3)
                                }
                                HStack(spacing: 12) {
                                    Button { togglePlayback() } label: {
                                        Label(isPlayingBack ? "Stop" : "Play",
                                              systemImage: isPlayingBack ? "stop.circle" : "play.circle")
                                            .font(.subheadline).fontWeight(.medium)
                                    }
                                    .buttonStyle(.bordered)

                                    Button {
                                        audioPlayer?.stop(); audioPlayer = nil
                                        isPlayingBack = false
                                        recorder.clearRecording()
                                    } label: {
                                        Label("Re-record", systemImage: "arrow.counterclockwise")
                                            .font(.subheadline)
                                    }
                                    .foregroundColor(.secondary)
                                }
                            }
                            .padding(16)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal)
                        }

                        if let err = recorder.error {
                            Text(err).font(.caption).foregroundColor(.red).padding(.horizontal)
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .navigationTitle("Repost with Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Repost") {
                        let data = recorder.recordedData
                        let transcript = recorder.transcript.isEmpty ? nil : recorder.transcript
                        dismiss()
                        onComplete(data, transcript)
                    }
                    .fontWeight(.semibold)
                    .disabled(recorder.isRecording)
                }
            }
        }
    }

    private func togglePlayback() {
        guard let data = recorder.recordedData else { return }
        if isPlayingBack {
            audioPlayer?.stop(); audioPlayer = nil; isPlayingBack = false
        } else {
            do {
                audioPlayer = try AVAudioPlayer(data: data)
                audioPlayer?.play()
                isPlayingBack = true
                Task {
                    let duration = audioPlayer?.duration ?? 0
                    try? await Task.sleep(for: .seconds(duration + 0.1))
                    isPlayingBack = false
                }
            } catch { isPlayingBack = false }
        }
    }
}
