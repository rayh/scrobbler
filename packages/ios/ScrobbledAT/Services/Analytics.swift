import Foundation
import PostHog

/// Thin wrapper around PostHog — all analytics calls go through here.
/// Swap the implementation without touching call sites.
enum Analytics {

    // MARK: - Identity

    /// Call after successful sign-in and whenever the profile is refreshed.
    static func identify(
        userId: String,
        handle: String,
        name: String? = nil,
        locationCity: String? = nil,
        locationCountry: String? = nil,
        createdAt: String? = nil
    ) {
        var props: [String: Any] = [
            "handle": handle,
            "stage": Config.stage,
        ]
        if let name, !name.isEmpty         { props["name"] = name }
        if let locationCity                { props["location_city"] = locationCity }
        if let locationCountry             { props["location_country"] = locationCountry }
        if let createdAt                   { props["created_at"] = createdAt }

        PostHogSDK.shared.identify(userId, userProperties: props)
    }

    /// Call on sign-out — clears the PostHog identity.
    static func reset() {
        PostHogSDK.shared.reset()
    }

    // MARK: - Social

    static func follow(targetHandle: String) {
        capture("follow", properties: ["target_handle": targetHandle])
    }

    static func unfollow(targetHandle: String) {
        capture("unfollow", properties: ["target_handle": targetHandle])
    }

    // MARK: - Feed

    static func like(postId: String, ownerHandle: String) {
        capture("like", properties: ["post_id": postId, "owner_handle": ownerHandle])
    }

    static func unlike(postId: String, ownerHandle: String) {
        capture("unlike", properties: ["post_id": postId, "owner_handle": ownerHandle])
    }

    // MARK: - Share

    static func shareTrack(trackTitle: String, artist: String, tags: [String]) {
        capture("share_track", properties: [
            "track_title": trackTitle,
            "artist": artist,
            "tags": tags.joined(separator: ","),
            "tag_count": tags.count,
        ])
    }

    // MARK: - Uploads

    static func uploadCompleted(type: String) {
        capture("upload_completed", properties: ["upload_type": type])
    }

    // MARK: - Errors

    /// Captures to PostHog's standard $exception event so errors surface in the PostHog errors view.
    static func error(_ message: String, context: String, underlyingError: Error? = nil) {
        var props: [String: Any] = [
            "$exception_message": message,
            "$exception_type": context,
            "context": context,
        ]
        if let underlyingError {
            props["underlying_error"] = underlyingError.localizedDescription
        }
        PostHogSDK.shared.capture("$exception", properties: props)
    }

    // MARK: - Private

    /// Adds `stage` to every event automatically.
    private static func capture(_ event: String, properties: [String: Any] = [:]) {
        var props = properties
        props["stage"] = Config.stage
        PostHogSDK.shared.capture(event, properties: props)
    }
}
