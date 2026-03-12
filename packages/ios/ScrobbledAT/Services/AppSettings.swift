import Foundation
import Combine

/// Central store for user-configurable app preferences.
/// All values are persisted in UserDefaults.standard via @AppStorage wrappers.
@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Keys
    private enum Keys {
        static let preferredMusicApp = "preferredMusicApp"
        static let hasSetMusicApp    = "hasSetMusicApp"
        static let appleMusicSyncEnabled = "appleMusicSyncEnabled"
        static let appleMusicSyncAsked = "appleMusicSyncAsked"
    }

    // MARK: - Preferred music app
    enum MusicApp: String, CaseIterable, Identifiable {
        case appleMusic = "appleMusic"
        case spotify    = "spotify"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .appleMusic: return "Apple Music"
            case .spotify:    return "Spotify"
            }
        }

        var iconName: String {
            switch self {
            case .appleMusic: return "music.note"
            case .spotify:    return "music.note.list"
            }
        }
    }

    @Published var preferredMusicApp: MusicApp {
        didSet { UserDefaults.standard.set(preferredMusicApp.rawValue, forKey: Keys.preferredMusicApp) }
    }

    /// `true` once the user has explicitly chosen a preferred music app.
    /// Used to trigger the first-run picker on the first cell tap.
    @Published var hasSetMusicApp: Bool {
        didSet { UserDefaults.standard.set(hasSetMusicApp, forKey: Keys.hasSetMusicApp) }
    }

    // MARK: - Apple Music sync
    /// Whether the user has opted in to having their Selector feed synced as an Apple Music playlist.
    @Published var appleMusicSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(appleMusicSyncEnabled, forKey: Keys.appleMusicSyncEnabled) }
    }

    /// Whether the user has already been asked about Apple Music sync (so we only ask once).
    @Published var appleMusicSyncAsked: Bool {
        didSet { UserDefaults.standard.set(appleMusicSyncAsked, forKey: Keys.appleMusicSyncAsked) }
    }

    // MARK: - Init

    private init() {
        let rawApp = UserDefaults.standard.string(forKey: Keys.preferredMusicApp) ?? ""
        preferredMusicApp = MusicApp(rawValue: rawApp) ?? .appleMusic
        hasSetMusicApp    = UserDefaults.standard.bool(forKey: Keys.hasSetMusicApp)
        appleMusicSyncEnabled = UserDefaults.standard.bool(forKey: Keys.appleMusicSyncEnabled)
        appleMusicSyncAsked   = UserDefaults.standard.bool(forKey: Keys.appleMusicSyncAsked)
    }
}
