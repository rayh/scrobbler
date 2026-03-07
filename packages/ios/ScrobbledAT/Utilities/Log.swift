import os.log

/// Centralised loggers for the ScrobbledAT app.
///
/// Usage:
///   Log.auth.info("Attempting sign in")
///   Log.auth.error("Sign in failed: \(error)")
///
/// Filter in Console.app: subsystem == "net.wirestorm.scrobbler"
/// Filter by area:         category == "auth"  (or push, feed, share, oauth, network)
enum Log {
    static let auth    = Logger(subsystem: "net.wirestorm.scrobbler", category: "auth")
    static let network = Logger(subsystem: "net.wirestorm.scrobbler", category: "network")
    static let push    = Logger(subsystem: "net.wirestorm.scrobbler", category: "push")
    static let feed    = Logger(subsystem: "net.wirestorm.scrobbler", category: "feed")
    static let share   = Logger(subsystem: "net.wirestorm.scrobbler", category: "share")
    static let oauth   = Logger(subsystem: "net.wirestorm.scrobbler", category: "oauth")
}
