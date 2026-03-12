import SwiftUI
import MusicKit

/// One-time sheet shown on first app launch after sign-in, asking
/// the user whether to sync their Selector feed to Apple Music.
struct AppleMusicSyncPromptView: View {
    @StateObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "music.note.list")
                .font(.system(size: 72))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )

            VStack(spacing: 12) {
                Text("Sync to Apple Music?")
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text("Selector can keep a playlist in your Apple Music library that stays in sync with your feed automatically.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(spacing: 12) {
                Button {
                    Task { await enableSync() }
                } label: {
                    if isRequesting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Yes, sync my feed")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequesting)

                Button("Not now") {
                    settings.appleMusicSyncAsked = true
                    dismiss()
                }
                .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
        .interactiveDismissDisabled()
    }

    private func enableSync() async {
        isRequesting = true
        let status = await MusicAuthorization.request()
        if status == .authorized {
            settings.appleMusicSyncEnabled = true
            await MusicSyncService.shared.syncFeedPlaylist()
        }
        settings.appleMusicSyncAsked = true
        isRequesting = false
        dismiss()
    }
}
