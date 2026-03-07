import SwiftUI

struct TrackCard: View {
    let share: MusicShare
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Sharer info
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
            
            // Track info with artwork
            HStack(spacing: 12) {
                // Artwork
                if let artworkUrl = share.track.artworkUrl {
                    AsyncImage(url: URL(string: artworkUrl)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.3))
                    }
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                // Track details
                VStack(alignment: .leading, spacing: 4) {
                    Text(share.track.title)
                        .font(.headline)
                        .lineLimit(2)
                    
                    Text(share.track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    if let album = share.track.album {
                        Text(album)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
            }
            
            // Comment
            if let comment = share.comment, !comment.isEmpty {
                Text(comment)
                    .font(.body)
                    .lineLimit(3)
            }
            
            // Tags
            if !share.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(share.tags, id: \.self) { tag in
                            TagChip(text: tag)
                        }
                    }
                }
            }
            
            // Actions
            HStack(spacing: 16) {
                Button {
                    // Play action
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button {
                    // More actions
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}

struct TagChip: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1))
            .foregroundColor(.accentColor)
            .clipShape(Capsule())
    }
}

// Date extension for relative time
extension Date {
    func timeAgo() -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

#Preview {
    TrackCard(share: MusicShare(
        id: "1",
        track: Track(
            id: "1",
            title: "Song Title",
            artist: "Artist Name",
            album: "Album Name",
            isrc: nil,
            sourceUrl: "",
            sourcePlatform: .spotify,
            artworkUrl: nil
        ),
        comment: "Perfect Sunday morning vibe",
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
