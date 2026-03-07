import Foundation
import os.log

// Service for ShareExtension - posts directly to backend
actor ShareExtensionService {
    private let logger = Logger(subsystem: "net.wirestorm.scrobbler", category: "shareService")
    
    func postTrack(track: Track, comment: String?, tags: [String], location: (lat: Double, lng: Double)?, userId: String, idToken: String, imageUrl: String? = nil, voiceMemoUrl: String? = nil) async throws {
        logger.info("🌐 Starting API call...")
        
        guard let url = URL(string: "\(Config.apiBaseUrl)/music/share") else {
            logger.error("❌ Invalid URL")
            throw ShareError.invalidURL
        }
        
        logger.info("🔗 URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        
        var payload: [String: Any] = [
            "userId": userId,
            "track": [
                "id": track.id,
                "title": track.title,
                "artist": track.artist,
                "album": track.album ?? "",
                "artworkUrl": track.artworkUrl ?? "",
                "appleMusicUrl": track.appleMusicUrl ?? ""
            ],
            "comment": comment ?? "",
            "tags": tags,
        ]
        if let location {
            payload["location"] = ["latitude": location.lat, "longitude": location.lng]
        }
        if let imageUrl { payload["imageUrl"] = imageUrl }
        if let voiceMemoUrl { payload["voiceMemoUrl"] = voiceMemoUrl }
        
        logger.info("📦 Payload: \(payload)")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            logger.info("✅ JSON serialized")
        } catch {
            logger.error("❌ JSON serialization failed: \(error)")
            throw error
        }
        
        logger.info("🚀 Making HTTP request...")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            logger.info("📥 Response received")
            
            if let httpResponse = response as? HTTPURLResponse {
                logger.info("📊 Status code: \(httpResponse.statusCode)")
                
                if let responseString = String(data: data, encoding: .utf8) {
                    logger.info("📄 Response body: \(responseString)")
                }
                
                if httpResponse.statusCode != 200 {
                    throw ShareError.serverError(httpResponse.statusCode)
                }
            }
            
            logger.info("✅ API call successful")
            Analytics.shareTrack(trackTitle: track.title, artist: track.artist, tags: tags)

        } catch {
            logger.error("❌ HTTP request failed: \(error)")
            Analytics.error("Share track failed", context: "ShareExtensionService", underlyingError: error)
            throw error
        }
    }
    
    // Queue a share for later posting when the main app is opened (fallback)
    func queueShare(track: Track, comment: String?, tags: [String], mood: String?) async throws -> String {
        let shareData: [String: Any] = [
            "track": [
                "title": track.title,
                "artist": track.artist,
                "album": track.album ?? "",
                "appleMusicUrl": track.appleMusicUrl ?? ""
            ],
            "comment": comment ?? "",
            "tags": tags,
            "mood": mood ?? "",
            "timestamp": Date().timeIntervalSince1970
        ]
        
        // Store in shared UserDefaults
        let sharedDefaults = UserDefaults(suiteName: "group.net.wirestorm.scrobbler")
        var pendingShares = sharedDefaults?.array(forKey: "pendingShares") as? [[String: Any]] ?? []
        pendingShares.append(shareData)
        sharedDefaults?.set(pendingShares, forKey: "pendingShares")
        
        return "queued-\(Date().timeIntervalSince1970)"
    }
}

enum ShareError: LocalizedError {
    case noUserProfile
    case invalidURL
    case serverError(Int)
    
    var errorDescription: String? {
        switch self {
        case .noUserProfile:
            return "User profile not found"
        case .invalidURL:
            return "Invalid server URL"
        case .serverError(let code):
            return "Server error: \(code)"
        }
    }
}
