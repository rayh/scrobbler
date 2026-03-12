import SwiftUI
import PhotosUI
import CoreLocation

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
    var followersCount: Int
    var followingCount: Int
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

        /// Convert to FeedService.FeedGroup for use with FeedPostCell.
        func asFeedGroup(userHandle: String) -> FeedService.FeedGroup {
            FeedService.FeedGroup(
                groupId: id,
                trackKey: nil,
                track: FeedService.FeedGroup.TrackInfo(
                    id: "",
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    artwork: track.artwork,
                    appleMusicUrl: track.appleMusicUrl,
                    spotifyUrl: nil
                ),
                windowStart: createdAt,
                lastUpdatedAt: createdAt,
                sharedBy: [
                    FeedService.FeedGroup.SharedByEntry(
                        postId: id,
                        userId: "",
                        userHandle: userHandle,
                        voiceMemoUrl: nil,
                        transcript: comment,
                        tags: tags,
                        createdAt: createdAt
                    )
                ],
                likes: 0,
                location: nil
            )
        }
    }
}

// MARK: - View model

@MainActor
class UserProfileViewModel: ObservableObject {
    @Published var profileData: UserProfileData?
    @Published var isLoading = false
    @Published var isFollowLoading = false
    @Published var followError: String?
    @Published var error: String?

    private let apiBaseUrl = Config.apiBaseUrl
    private static let cacheTTL: TimeInterval = 30
    private var lastLoadedAt: Date?
    private var lastLoadedHandle: String?

    private func isFresh(for key: String) -> Bool {
        guard lastLoadedHandle == key, let t = lastLoadedAt else { return false }
        return Date().timeIntervalSince(t) < Self.cacheTTL
    }

    func load(handle: String, force: Bool = false) async {
        guard force || !isFresh(for: handle) else {
            print("⏭️ UserProfileVM: /users/\(handle) — cache still fresh, skipping")
            return
        }
        isLoading = true
        error = nil
        print("➡️ UserProfileVM: GET /users/\(handle)")
        do {
            guard let url = URL(string: "\(apiBaseUrl)/users/\(handle.lowercased())") else { return }
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse else { return }
            print("✅ UserProfileVM: /users/\(handle) → HTTP \(http.statusCode)")
            if http.statusCode == 404 {
                error = "User not found"
                isLoading = false
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            profileData = parseProfile(json)
            lastLoadedHandle = handle
            lastLoadedAt = Date()
        } catch {
            print("❌ UserProfileVM: /users/\(handle) threw \(error)")
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func toggleFollow(handle: String) async {
        let socialService = SocialService.shared
        isFollowLoading = true
        followError = nil
        socialService.error = nil
        if socialService.isFollowing(handle: handle) {
            await socialService.unfollow(handle: handle)
        } else {
            await socialService.follow(handle: handle)
        }
        followError = socialService.error
        isFollowLoading = false
        await socialService.loadFollowing()
    }

    private func parseProfile(_ json: [String: Any], rawPosts overridePosts: [[String: Any]]? = nil) -> UserProfileData {
        var city: String?
        var country: String?
        if let loc = json["location"] as? [String: Any] {
            city = loc["city"] as? String
            country = loc["country"] as? String
        }

        let rawPostsArray = overridePosts ?? (json["posts"] as? [[String: Any]] ?? [])
        let posts: [UserProfileData.UserProfilePost] = rawPostsArray.compactMap { p in
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
            followersCount: json["followersCount"] as? Int ?? 0,
            followingCount: json["followingCount"] as? Int ?? 0,
            posts: posts
        )
    }
}

// MARK: - Main View

struct UserProfileView: View {
    let handle: String
    var isOwnProfile: Bool = false
    var isModal: Bool = false
    var onDismiss: (() -> Void)? = nil

    // Used only for other-user profiles
    @StateObject private var vm = UserProfileViewModel()
    @ObservedObject private var socialService = SocialService.shared
    // Own-profile data comes directly from ProfileService — no separate ViewModel load
    @ObservedObject private var profileService = ProfileService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showingAvatarPicker = false
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @ObservedObject private var locationService = LocationService.shared
    // Needed so FeedPostCell children can read it
    @EnvironmentObject private var appleSignInService: AppleSignInService

    // Resolve which data + loading state to show depending on profile mode
    private var displayData: UserProfileData? {
        isOwnProfile ? profileService.ownProfileData : vm.profileData
    }
    private var displayLoading: Bool {
        isOwnProfile ? profileService.isLoading : vm.isLoading
    }
    private var displayError: String? {
        isOwnProfile ? profileService.error : vm.error
    }

    var body: some View {
        Group {
            if displayLoading && displayData == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = displayError {
                VStack(spacing: 12) {
                    Image(systemName: "person.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(err)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        Task {
                            if isOwnProfile { await profileService.loadMyProfile(force: true) }
                            else { await vm.load(handle: handle, force: true) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let profile = displayData {
                profileContent(profile)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(isOwnProfile ? "Profile" : "@\(handle)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isOwnProfile {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .task {
            if isOwnProfile {
                // ProfileService.loadMyProfile() was already called by MainTabView.task.
                // The in-flight guard collapses any concurrent call; if fresh data is already
                // present, this returns immediately without a network request.
                await profileService.loadMyProfile()
                await captureLocationIfNeeded()
            } else {
                let social = socialService
                let model = vm
                async let followingLoad: () = social.loadFollowingIfNeeded()
                async let profileLoad: () = model.load(handle: handle)
                _ = await (followingLoad, profileLoad)
            }
        }
        .refreshable {
            if isOwnProfile { await profileService.loadMyProfile(force: true) }
            else { await vm.load(handle: handle, force: true) }
        }
        .photosPicker(
            isPresented: $showingAvatarPicker,
            selection: $selectedPhoto,
            matching: .images
        )
        .onChange(of: selectedPhoto) { newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    await profileService.uploadAvatar(data)
                    await profileService.loadMyProfile(force: true)
                }
                selectedPhoto = nil
            }
        }
    }

    // MARK: - Content

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
                    LazyVStack(spacing: 0) {
                        ForEach(profile.posts) { post in
                            FeedPostCell(
                                group: post.asFeedGroup(userHandle: profile.handle),
                                showUser: false,
                                hideActions: isOwnProfile
                            )
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, 0)
                }
            }
        }
        .environmentObject(FeedService.shared)
        .environmentObject(AppSettings.shared)
    }

    // MARK: - Profile Header

    @ViewBuilder
    private func profileHeader(_ profile: UserProfileData) -> some View {
        VStack(spacing: 16) {
            // Avatar
            Group {
                if isOwnProfile {
                    // Tappable avatar with camera badge
                    Button { showingAvatarPicker = true } label: {
                        ZStack(alignment: .bottomTrailing) {
                            avatarImage(profile, size: 80)
                            if profileService.isUploadingAvatar {
                                ProgressView()
                                    .padding(4)
                                    .background(Color(.systemBackground))
                                    .clipShape(Circle())
                                    .offset(x: 2, y: 2)
                            } else {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(5)
                                    .background(Color.blue)
                                    .clipShape(Circle())
                                    .offset(x: 2, y: 2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    avatarImage(profile, size: 80)
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

            // Followers / Following counts
            HStack(spacing: 32) {
                NavigationLink(destination: FollowersView()) {
                    VStack(spacing: 2) {
                        Text("\(profile.followersCount)")
                            .font(.headline)
                            .fontWeight(.bold)
                        Text("Followers")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                if isOwnProfile {
                    NavigationLink(destination: FollowingView()) {
                        VStack(spacing: 2) {
                            Text("\(profile.followingCount)")
                                .font(.headline)
                                .fontWeight(.bold)
                            Text("Following")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    VStack(spacing: 2) {
                        Text("\(profile.followingCount)")
                            .font(.headline)
                            .fontWeight(.bold)
                        Text("Following")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Location
            if let loc = profile.locationDisplay {
                Label(loc, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Follow / Unfollow — only for other profiles when authenticated
            if !isOwnProfile && socialService.isAuthenticated {
                let following = socialService.isFollowing(handle: profile.handle)
                VStack(spacing: 6) {
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

                    if let err = vm.followError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }

    // MARK: - Avatar helpers

    @ViewBuilder
    private func avatarImage(_ profile: UserProfileData, size: CGFloat) -> some View {
        if let avatarUrl = profile.avatarUrl, let url = URL(string: avatarUrl) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                avatarPlaceholder(profile, size: size)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            avatarPlaceholder(profile, size: size)
        }
    }

    @ViewBuilder
    private func avatarPlaceholder(_ profile: UserProfileData, size: CGFloat) -> some View {
        Circle()
            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Text(String(profile.name?.first ?? profile.handle.first ?? "?").uppercased())
                    .foregroundColor(.white)
                    .font(size >= 60 ? .title : .subheadline)
                    .fontWeight(.medium)
            )
    }

    // MARK: - Location capture (own profile only)

    private func captureLocationIfNeeded() async {
        guard profileService.profile?.location == nil else { return }

        let status = locationService.authorizationStatus
        if status == .notDetermined {
            locationService.requestLocationPermission()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        guard locationService.authorizationStatus == .authorizedWhenInUse
                || locationService.authorizationStatus == .authorizedAlways else { return }

        locationService.getCurrentLocation()

        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if locationService.currentLocation != nil { break }
        }

        guard let clLocation = locationService.currentLocation else { return }
        guard let loc = await profileService.reverseGeocodeCurrentLocation(clLocation) else { return }
        await profileService.updateProfile(location: loc)
    }
}

// MARK: - Edit Bio Sheet

struct EditBioSheet: View {
    @Binding var bio: String
    let onDismiss: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("Bio") {
                    TextEditor(text: $bio)
                        .frame(minHeight: 80)
                }
                Section {
                    Text("\(bio.count)/160 characters")
                        .font(.caption)
                        .foregroundColor(bio.count > 160 ? .red : .secondary)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss(false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onDismiss(true)
                        dismiss()
                    }
                    .disabled(bio.count > 160)
                }
            }
        }
    }
}

// MARK: - String helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
