import Foundation
import MusicKit
import os.log

class MusicMetadataService: @unchecked Sendable {
    private let logger = Logger(subsystem: "net.wirestorm.scrobbler", category: "metadata")
    
    func extractMetadata(from urlString: String) async throws -> Track {
        logger.info("🔍 Starting metadata extraction for URL: \(urlString)")
        
        // Parse URL first
        guard let url = URL(string: urlString) else {
            logger.error("❌ Invalid URL: \(urlString)")
            throw MusicError.invalidURL
        }
        
        logger.info("🔗 Host: \(url.host ?? "none")")
        
        // Check if it's Apple Music
        guard let host = url.host, host.contains("music.apple.com") else {
            logger.error("❌ Only Apple Music URLs supported for now")
            throw MusicError.unsupportedPlatform
        }
        
        // MUST have MusicKit authorization to get metadata
        let authStatus = MusicAuthorization.currentStatus
        logger.info("🎵 MusicKit status: \(String(describing: authStatus))")
        
        if authStatus != .authorized {
            logger.info("🎵 Requesting MusicKit authorization...")
            let newStatus = await MusicAuthorization.request()
            logger.info("🎵 New status: \(String(describing: newStatus))")
            
            if newStatus != .authorized {
                logger.error("❌ MusicKit authorization required")
                throw MusicError.notAuthorized
            }
        }
        
        // Extract track ID from Apple Music URL
        guard let trackId = extractTrackId(from: url) else {
            logger.error("❌ Could not extract track ID from URL")
            throw MusicError.invalidURL
        }
        
        logger.info("🍎 Found track ID: \(trackId)")
        
        // Search MusicKit for the track
        do {
            let musicItemID = MusicItemID(trackId)
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: musicItemID)
            let response = try await request.response()
            
            logger.info("🍎 MusicKit found \(response.items.count) items")
            
            guard let song = response.items.first else {
                logger.error("❌ Track not found in MusicKit")
                throw MusicError.searchFailed("Track not found")
            }
            
            logger.info("✅ Found: \(song.title) by \(song.artistName)")
            
            return Track(
                id: song.id.rawValue,
                title: song.title,
                artist: song.artistName,
                album: song.albumTitle,
                isrc: song.isrc,
                spotifyUrl: nil,
                appleMusicUrl: url.absoluteString,
                youtubeMusicUrl: nil,
                sourceUrl: url.absoluteString,
                sourcePlatform: .appleMusic,
                artworkUrl: song.artwork?.url(width: 300, height: 300)?.absoluteString
            )
            
        } catch {
            logger.error("❌ MusicKit search failed: \(error)")
            throw MusicError.searchFailed(error.localizedDescription)
        }
    }
    
    private func extractFromAppleMusic(url: URL) async throws -> Track {
        logger.info("🍎 Processing Apple Music URL")
        
        // First try to extract without MusicKit (for basic info)
        let basicTrack = try parseAppleMusicURL(url: url)
        
        // Check MusicKit authorization
        let authStatus = MusicAuthorization.currentStatus
        logger.info("🎵 MusicKit authorization status: \(String(describing: authStatus))")
        
        if authStatus != .authorized {
            logger.warning("⚠️ MusicKit not authorized, requesting permission...")
            let newStatus = await MusicAuthorization.request()
            logger.info("🎵 New authorization status: \(String(describing: newStatus))")
            
            if newStatus != .authorized {
                logger.warning("⚠️ MusicKit authorization denied, returning basic track info")
                return basicTrack
            }
        }
        
        // Try to enhance with MusicKit if we have a track ID
        if let trackId = extractTrackId(from: url) {
            logger.info("🍎 Found track ID: \(trackId), searching with MusicKit...")
            
            do {
                let musicItemID = MusicItemID(trackId)
                let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: musicItemID)
                let response = try await request.response()
                
                logger.info("🍎 MusicKit response: \(response.items.count) items found")
                
                if let song = response.items.first {
                    logger.info("✅ Enhanced track with MusicKit: \(song.title) by \(song.artistName)")
                    
                    return Track(
                        id: song.id.rawValue,
                        title: song.title,
                        artist: song.artistName,
                        album: song.albumTitle,
                        isrc: song.isrc,
                        spotifyUrl: nil,
                        appleMusicUrl: url.absoluteString,
                        youtubeMusicUrl: nil,
                        sourceUrl: url.absoluteString,
                        sourcePlatform: .appleMusic,
                        artworkUrl: song.artwork?.url(width: 300, height: 300)?.absoluteString
                    )
                }
            } catch {
                logger.error("❌ MusicKit search failed: \(error), falling back to basic info")
            }
        }
        
        logger.info("✅ Returning basic track info")
        return basicTrack
    }
    
    private func parseAppleMusicURL(url: URL) throws -> Track {
        logger.info("🔍 Parsing Apple Music URL for basic info")
        
        let pathComponents = url.pathComponents
        logger.info("🔍 Path components: \(pathComponents)")
        
        // Try to extract album and track names from path
        var albumName: String?
        var trackTitle: String?
        var artistName: String?
        
        // Look for album in path like /us/album/album-name/id
        if let albumIndex = pathComponents.firstIndex(of: "album"),
           albumIndex + 1 < pathComponents.count {
            let albumComponent = pathComponents[albumIndex + 1]
            // Remove ID part if present
            if let slashIndex = albumComponent.firstIndex(of: "/") {
                albumName = String(albumComponent[..<slashIndex]).replacingOccurrences(of: "-", with: " ").capitalized
            } else {
                albumName = albumComponent.replacingOccurrences(of: "-", with: " ").capitalized
            }
        }
        
        // For now, create a basic track with URL info
        // In a real app, you might want to scrape the page or use other APIs
        return Track(
            id: UUID().uuidString,
            title: trackTitle ?? "Unknown Track",
            artist: artistName ?? "Unknown Artist", 
            album: albumName ?? "Unknown Album",
            isrc: nil,
            spotifyUrl: nil,
            appleMusicUrl: url.absoluteString,
            youtubeMusicUrl: nil,
            sourceUrl: url.absoluteString,
            sourcePlatform: .appleMusic,
            artworkUrl: nil
        )
    }
    
    private func extractTrackId(from url: URL) -> String? {
        // Look for track ID in query parameters (i=trackId)
        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            return queryItems.first(where: { $0.name == "i" })?.value
        }
        return nil
    }
    
    private func extractFromSpotify(url: URL) async throws -> Track {
        logger.info("🎵 Processing Spotify URL")
        
        // For Spotify, we'd need to use their API or web scraping
        // For now, return basic info from URL
        return try parseSpotifyURL(url: url)
    }
    
    private func parseSpotifyURL(url: URL) throws -> Track {
        logger.info("🔍 Parsing Spotify URL for basic info")
        
        let pathComponents = url.pathComponents
        logger.info("🔍 Path components: \(pathComponents)")
        
        // Spotify URLs are like /track/trackId or /album/albumId
        var trackId: String?
        if let trackIndex = pathComponents.firstIndex(of: "track"),
           trackIndex + 1 < pathComponents.count {
            trackId = pathComponents[trackIndex + 1]
        }
        
        return Track(
            id: trackId ?? UUID().uuidString,
            title: "Unknown Track",
            artist: "Unknown Artist",
            album: "Unknown Album", 
            isrc: nil,
            spotifyUrl: url.absoluteString,
            appleMusicUrl: nil,
            youtubeMusicUrl: nil,
            sourceUrl: url.absoluteString,
            sourcePlatform: .spotify,
            artworkUrl: nil
        )
    }
}

enum MusicError: LocalizedError {
    case notAuthorized
    case invalidURL
    case unsupportedPlatform
    case searchFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Music access not authorized. Please allow access to Apple Music in Settings."
        case .invalidURL:
            return "Invalid music URL"
        case .unsupportedPlatform:
            return "Unsupported music platform. Please share from Apple Music or Spotify."
        case .searchFailed(let message):
            return "Failed to find track: \(message)"
        }
    }
}
