import SwiftUI
import MusicKit

struct MusicShareView: View {
    @EnvironmentObject var feedService: FeedService
    @StateObject private var musicService = MusicService()
    @StateObject private var locationService = LocationService()

    @State private var recentTracks: [Song] = []
    @State private var searchQuery = ""
    @State private var searchResults: [Song] = []
    @State private var isSearching = false
    @State private var selectedSong: Song?
    @State private var comment = ""
    @State private var tags = ""
    @State private var shareLocation = false
    @State private var isSharing = false
    @State private var shareError: String?
    @State private var shareSuccess = false

    private var displayedTracks: [Song] {
        searchQuery.isEmpty ? recentTracks : searchResults
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {

                    // ── Authorization gate ────────────────────────────────
                    if musicService.authorizationStatus == .notDetermined {
                        sectionCard(title: "Apple Music Access") {
                            Button("Allow Access to Apple Music") {
                                Task { await musicService.requestMusicAuthorization() }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else if musicService.authorizationStatus == .denied {
                        sectionCard(title: "Apple Music Access") {
                            Text("Apple Music access is required to share tracks. Enable it in Settings.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    } else {

                        // ── Track picker ──────────────────────────────────
                        sectionCard(title: selectedSong == nil ? "Choose a Track" : "Track") {
                            if let song = selectedSong {
                                selectedTrackRow(song)
                            } else {
                                VStack(spacing: 10) {
                                    HStack {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundColor(.secondary)
                                        TextField("Search Apple Music...", text: $searchQuery)
                                            .autocorrectionDisabled()
                                            .onChange(of: searchQuery) { query in
                                                Task { await performSearch(query: query) }
                                            }
                                        if !searchQuery.isEmpty {
                                            Button { searchQuery = "" } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                    .padding(10)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))

                                    if isSearching {
                                        ProgressView().padding(.vertical, 8)
                                    } else if displayedTracks.isEmpty && !searchQuery.isEmpty {
                                        Text("No results")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .padding(.vertical, 8)
                                    } else {
                                        if searchQuery.isEmpty {
                                            Text("Recently Played")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        ForEach(displayedTracks, id: \.id) { song in
                                            trackRow(song)
                                        }
                                    }
                                }
                            }
                        }

                        // ── Comment ───────────────────────────────────────
                        sectionCard(title: "What do you think?") {
                            ZStack(alignment: .topLeading) {
                                if comment.isEmpty {
                                    Text("Add a comment...")
                                        .foregroundColor(.secondary)
                                        .padding(.top, 8)
                                        .padding(.leading, 4)
                                }
                                TextEditor(text: $comment)
                                    .frame(minHeight: 80)
                                    .scrollContentBackground(.hidden)
                            }
                        }

                        // ── Tags ──────────────────────────────────────────
                        sectionCard(title: "Tags") {
                            TextField("#chill  #weekend  #coding", text: $tags)
                                .autocorrectionDisabled()
                                .autocapitalization(.none)
                        }

                        // ── Location ──────────────────────────────────────
                        sectionCard(title: "Location") {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("Share my location", isOn: $shareLocation)
                                if shareLocation && locationService.authorizationStatus != .authorizedWhenInUse {
                                    Button("Enable Location Access") {
                                        locationService.requestLocationPermission()
                                    }
                                    .font(.subheadline)
                                    .foregroundColor(.accentColor)
                                }
                                if shareLocation && locationService.authorizationStatus == .authorizedWhenInUse {
                                    Label("Location will be attached", systemImage: "location.fill")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        // ── Error banner ──────────────────────────────────
                        if let err = shareError {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(err)
                                    .font(.subheadline)
                                    .foregroundColor(.red)
                                Spacer()
                                Button { shareError = nil } label: {
                                    Image(systemName: "xmark").foregroundColor(.secondary)
                                }
                            }
                            .padding()
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                        }

                        // ── Share button ──────────────────────────────────
                        Button(action: shareTrack) {
                            Group {
                                if isSharing {
                                    HStack(spacing: 10) {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        Text("Sharing...")
                                    }
                                } else {
                                    Text("Share Track").fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedSong == nil || isSharing)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if musicService.authorizationStatus == .notDetermined {
                    await musicService.requestMusicAuthorization()
                }
                if musicService.authorizationStatus == .authorized {
                    recentTracks = await musicService.getRecentlyPlayedSongs()
                }
            }
            .alert("Shared!", isPresented: $shareSuccess) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your track has been shared with your followers.")
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
            VStack(alignment: .leading) {
                content()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func trackRow(_ song: Song) -> some View {
        Button { selectedSong = song } label: {
            HStack(spacing: 12) {
                artworkImage(song.artwork, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundColor(.primary).lineLimit(1)
                    Text(song.artistName)
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func selectedTrackRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            artworkImage(song.artwork, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.headline).lineLimit(1)
                Text(song.artistName)
                    .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                if let album = song.albumTitle {
                    Text(album).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { selectedSong = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 20))
            }
        }
    }

    @ViewBuilder
    private func artworkImage(_ artwork: MusicKit.Artwork?, size: CGFloat) -> some View {
        Group {
            if let url = artwork?.url(width: Int(size * 2), height: Int(size * 2)) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    artworkPlaceholder
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.systemGray5))
            .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
    }

    // MARK: - Actions

    private func performSearch(query: String) async {
        guard !query.isEmpty else { searchResults = []; return }
        isSearching = true
        searchResults = await musicService.searchSongs(query: query)
        isSearching = false
    }

    @MainActor
    private func shareTrack() {
        guard let song = selectedSong, !isSharing else { return }
        shareError = nil
        isSharing = true

        let location: (lat: Double, lng: Double)?
        if shareLocation, locationService.authorizationStatus == .authorizedWhenInUse {
            locationService.getCurrentLocation()
            location = locationService.getLocationForSharing().map { (lat: $0.latitude, lng: $0.longitude) }
        } else {
            location = nil
        }

        Task {
            defer { Task { @MainActor in isSharing = false } }

            guard let idToken = KeychainService.shared.get(key: "idToken") else {
                await MainActor.run { shareError = "Not signed in" }
                return
            }

            let userId = jwtSub(from: idToken) ?? ""
            let parsedTags = tags
                .components(separatedBy: .whitespaces)
                .filter { $0.hasPrefix("#") }
                .map { String($0.dropFirst()) }
                .filter { !$0.isEmpty }

            let appleMusicUrl = song.url?.absoluteString
            let track = Track(
                id: song.id.rawValue,
                title: song.title,
                artist: song.artistName,
                album: song.albumTitle,
                isrc: song.isrc,
                spotifyUrl: nil,
                appleMusicUrl: appleMusicUrl,
                youtubeMusicUrl: nil,
                sourceUrl: appleMusicUrl ?? "",
                sourcePlatform: .appleMusic,
                artworkUrl: song.artwork?.url(width: 600, height: 600)?.absoluteString
            )

            let service = ShareExtensionService()
            do {
                try await service.postTrack(
                    track: track,
                    comment: comment.isEmpty ? nil : comment,
                    tags: parsedTags,
                    location: location,
                    userId: userId,
                    idToken: idToken
                )
                await MainActor.run {
                    selectedSong = nil
                    comment = ""
                    tags = ""
                    shareLocation = false
                    shareSuccess = true
                }
            } catch {
                await MainActor.run { shareError = error.localizedDescription }
            }
        }
    }

    private func jwtSub(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["sub"] as? String
    }
}
