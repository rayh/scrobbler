import SwiftUI
import MusicKit

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var musicService = MusicService.shared
    @StateObject private var musicSyncService = MusicSyncService.shared
    @State private var musicAuthStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus

    var body: some View {
        Form {
            // MARK: - Location
            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Label("Location Sharing", systemImage: "location.fill")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
                .foregroundColor(.primary)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Controls whether Selector can attach your location to shared tracks.")
            }

            // MARK: - Music app
            Section {
                Picker("Preferred Music App", selection: $settings.preferredMusicApp) {
                    ForEach(AppSettings.MusicApp.allCases) { app in
                        Label(app.displayName, systemImage: app.iconName).tag(app)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Music")
            } footer: {
                Text("Used when opening track links from the feed.")
            }

            // MARK: - Apple Music sync
            Section {
                Toggle(isOn: syncToggleBinding) {
                    Label("Sync feed to Apple Music", systemImage: "music.note.list")
                }
                .disabled(musicAuthStatus == .denied || musicAuthStatus == .restricted)

                if settings.appleMusicSyncEnabled && musicAuthStatus == .authorized {
                    Button {
                        Task { await MusicSyncService.shared.syncFeedPlaylist() }
                    } label: {
                        HStack {
                            Label("Sync playlist now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if musicSyncService.isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(musicSyncService.isSyncing)

                    if let syncError = musicSyncService.lastSyncError {
                        Text(syncError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                if musicAuthStatus == .denied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Grant Apple Music access in Settings", systemImage: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            } header: {
                Text("Apple Music")
            } footer: {
                Text("When enabled, Selector keeps a playlist in your Apple Music library that mirrors your feed.")
            }

            // MARK: - Account
            Section {
                Button(role: .destructive) {
                    NotificationCenter.default.post(name: .forceLogout, object: nil)
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            musicAuthStatus = MusicAuthorization.currentStatus
        }
        .onChange(of: settings.appleMusicSyncEnabled) { _, enabled in
            if enabled { Task { await requestMusicAccessIfNeeded() } }
        }
    }

    // MARK: - Helpers

    /// Binding that requests MusicKit auth before enabling sync.
    private var syncToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.appleMusicSyncEnabled },
            set: { newValue in
                if newValue {
                    Task { await enableSyncWithAuth() }
                } else {
                    settings.appleMusicSyncEnabled = false
                }
            }
        )
    }

    private func enableSyncWithAuth() async {
        let status = await MusicAuthorization.request()
        musicAuthStatus = status
        if status == .authorized {
            settings.appleMusicSyncEnabled = true
            settings.appleMusicSyncAsked = true
            await MusicSyncService.shared.syncFeedPlaylist()
        } else {
            settings.appleMusicSyncEnabled = false
        }
    }

    private func requestMusicAccessIfNeeded() async {
        if musicAuthStatus == .notDetermined {
            musicAuthStatus = await MusicAuthorization.request()
        }
    }
}
