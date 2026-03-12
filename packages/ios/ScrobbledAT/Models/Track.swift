import Foundation

// Universal track representation
struct Track: Identifiable, Codable {
    let id: String // ISRC if available, otherwise generated
    let title: String
    let artist: String
    let album: String?
    let isrc: String?
    
    // Platform-specific URLs (populated at share time if possible)
    var spotifyUrl: String?
    var appleMusicUrl: String?
    var youtubeMusicUrl: String?
    
    // Original source
    let sourceUrl: String
    let sourcePlatform: MusicPlatform
    
    // Artwork
    var artworkUrl: String?

    // Genres from Apple Music catalog (populated at share time via MusicKit)
    var genres: [String]?
}

enum MusicPlatform: String, Codable {
    case spotify
    case appleMusic
    case youtubeMusic
    case unknown
    
    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        case .youtubeMusic: return "YouTube Music"
        case .unknown: return "Unknown"
        }
    }
}

// Music share (AT Protocol record)
struct MusicShare: Identifiable, Codable {
    let id: String // Post URI
    let track: Track
    let comment: String?
    let tags: [String]
    let mood: String?
    let sharer: User
    let createdAt: Date
}

struct User: Identifiable, Codable {
    let id: String
    let did: String
    let handle: String
    let displayName: String?
    let avatarUrl: String?
}
