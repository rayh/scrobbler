import SwiftUI

struct RichTrackCard: View {
    let share: MusicShare
    var showSharer: Bool = true
    
    @State private var showingMenu = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sharer info (if showing)
            if showSharer {
                HStack(spacing: 8) {
                    if let avatarUrl = share.sharer.avatarUrl {
                        AsyncImage(url: URL(string: avatarUrl)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(share.sharer.displayName ?? share.sharer.handle)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text(share.createdAt.timeAgo())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top)
            }
            
            // Large artwork with track info overlay
            ZStack(alignment: .bottomLeading) {
                // Artwork
                if let artworkUrl = share.track.artworkUrl {
                    AsyncImage(url: URL(string: artworkUrl)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    }
                    .frame(height: 300)
                    .clipped()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 300)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                        }
                }
                
                // Gradient overlay
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 300)
                
                // Track info on artwork
                VStack(alignment: .leading, spacing: 4) {
                    Text(share.track.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    Text(share.track.artist)
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.9))
                    
                    if let album = share.track.album {
                        Text(album)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding()
            }
            
            // Comment
            if let comment = share.comment, !comment.isEmpty {
                Text(comment)
                    .font(.body)
                    .padding()
            }
            
            // Tags
            if !share.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(share.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.1))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 8)
            }
            
            // Actions
            HStack(spacing: 16) {
                // Open in... menu
                Menu {
                    if let spotifyUrl = share.track.spotifyUrl {
                        Button {
                            openURL(spotifyUrl)
                        } label: {
                            Label("Open in Spotify", systemImage: "music.note")
                        }
                    }
                    
                    if let appleMusicUrl = share.track.appleMusicUrl {
                        Button {
                            openURL(appleMusicUrl)
                        } label: {
                            Label("Open in Apple Music", systemImage: "applelogo")
                        }
                    }
                    
                    if let youtubeUrl = share.track.youtubeMusicUrl {
                        Button {
                            openURL(youtubeUrl)
                        } label: {
                            Label("Open in YouTube Music", systemImage: "play.rectangle")
                        }
                    }
                } label: {
                    Label("Open in...", systemImage: "arrow.up.forward.app")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button {
                    // Share action
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                
                Button {
                    // More actions
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
    
    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    ScrollView {
        RichTrackCard(share: MusicShare(
            id: "1",
            track: Track(
                id: "1",
                title: "Song Title",
                artist: "Artist Name",
                album: "Album Name",
                isrc: nil,
                spotifyUrl: "https://open.spotify.com/track/123",
                appleMusicUrl: "https://music.apple.com/song/123",
                youtubeMusicUrl: nil,
                sourceUrl: "",
                sourcePlatform: .appleMusic,
                artworkUrl: nil
            ),
            comment: "Perfect Sunday morning vibe ☕️",
            tags: ["chill", "sunday", "coffee"],
            mood: nil,
            sharer: User(
                id: "user-sarah-001",
                did: "did:plc:test",
                handle: "sarah.bsky.social",
                displayName: "Sarah",
                avatarUrl: nil
            ),
            createdAt: Date().addingTimeInterval(-3600)
        ))
        .padding()
    }
}
