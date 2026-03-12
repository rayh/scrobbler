import Foundation
import MusicKit

/// Syncs the user's Selector feed into an Apple Music playlist named "Selector Feed".
///
/// Strategy: single stable playlist (never recreated), deduplication on every sync.
/// Only songs not already in the playlist are added. Songs are appended in feed order
/// (newest share first within each batch), so the most recently added batch sits at
/// the bottom of the playlist. Apple Music's "Recently Added" sort can be used to
/// surface new tracks. MusicKit provides no reorder or delete API.
///
/// Call `syncFeedPlaylist()` after the feed loads whenever appleMusicSyncEnabled is true.
@MainActor
class MusicSyncService: ObservableObject {
    static let shared = MusicSyncService()

    private let playlistName = "Selector Feed"
    @Published var isSyncing = false
    @Published var lastSyncError: String?

    // MARK: - Public API

    func syncFeedPlaylist() async {
        guard AppSettings.shared.appleMusicSyncEnabled else { return }
        guard MusicAuthorization.currentStatus == .authorized else { return }

        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        do {
            let groups = FeedService.shared.groups
            guard !groups.isEmpty else { return }

            // 1. Resolve feed groups → Apple Music track IDs (feed is newest-first)
            let feedIds: [MusicItemID] = groups.compactMap { group in
                guard let urlStr = group.track.appleMusicUrl,
                      let url = URL(string: urlStr),
                      let id = extractAppleMusicId(from: url) else { return nil }
                return MusicItemID(id)
            }
            guard !feedIds.isEmpty else { return }

            // 2. Fetch Song objects for feed IDs
            let catalogRequest = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: feedIds)
            let catalogResponse = try await catalogRequest.response()
            guard !catalogResponse.items.isEmpty else { return }

            // Preserve feed order (newest first)
            var songById: [MusicItemID: Song] = [:]
            for song in catalogResponse.items { songById[song.id] = song }
            let feedSongs: [Song] = feedIds.compactMap { songById[$0] }

            // 3. Find or create the single stable playlist
            let playlist = try await findOrCreatePlaylist(named: playlistName)

            // 4. Load existing playlist tracks to build a dedup set
            let loaded = try await playlist.with([.tracks])
            let existingIds: Set<MusicItemID> = Set((loaded.tracks ?? []).compactMap { $0.id })

            // 5. Filter to only songs not already present
            let newSongs = feedSongs.filter { !existingIds.contains($0.id) }

            guard !newSongs.isEmpty else {
                print("⏭️ MusicSyncService: no new tracks to add to '\(playlistName)'")
                return
            }

            // 6. Append new songs one by one (MusicKit has no batch-add API)
            for song in newSongs {
                try await MusicLibrary.shared.add(song, to: playlist)
            }

            print("✅ MusicSyncService: added \(newSongs.count) new track(s) to '\(playlistName)' (\(existingIds.count + newSongs.count) total)")
        } catch {
            lastSyncError = error.localizedDescription
            print("❌ MusicSyncService: sync failed — \(error)")
        }
    }

    // MARK: - Helpers

    /// Extracts the Apple Music track ID from an `?i=<id>` query parameter or `/<id>` path component.
    private func extractAppleMusicId(from url: URL) -> String? {
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "i" })?.value {
            return id
        }
        return url.pathComponents.last.flatMap { Int($0) != nil ? $0 : nil }
    }

    /// Returns an existing "Selector Feed" playlist or creates one if it doesn't exist.
    private func findOrCreatePlaylist(named name: String) async throws -> Playlist {
        var libraryRequest = MusicLibraryRequest<Playlist>()
        libraryRequest.filter(matching: \.name, equalTo: name)
        let response = try await libraryRequest.response()

        if let existing = response.items.first {
            return existing
        }

        return try await MusicLibrary.shared.createPlaylist(
            name: name,
            description: "Your Selector feed, kept in sync automatically.",
            authorDisplayName: nil,
            items: [Song]()
        )
    }
}
