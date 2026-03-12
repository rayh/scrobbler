import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var feedService: FeedService
    @EnvironmentObject var appleSignInService: AppleSignInService

    var body: some View {
        TabView {
            FeedView()
                .tabItem {
                    Image(systemName: "music.note.list")
                    Text("Feed")
                }

            LocationFeedView()
                .tabItem {
                    Image(systemName: "location")
                    Text("Nearby")
                }

            ProfileView()
                .tabItem {
                    Image(systemName: "person.circle")
                    Text("Profile")
                }
        }
        .task {
            // Pre-fetch profile so it's ready when user navigates to the Profile tab.
            // Location is fetched by LocationFeedView.onAppear — no need to duplicate here.
            async let _ = prefetchProfile()
        }
    }

    private func prefetchProfile() async {
        guard appleSignInService.isAuthenticated else { return }
        await ProfileService.shared.loadMyProfile()
    }
}

// MARK: - ProfileView (own profile tab)

/// Thin wrapper: loads current user's handle once, then renders UserProfileView
/// in own-profile mode. Uses local @State to avoid re-triggering on ProfileService publishes.
struct ProfileView: View {
    @State private var handle: String? = ProfileService.shared.profile?.handle

    var body: some View {
        NavigationView {
            Group {
                if let handle, !handle.isEmpty {
                    UserProfileView(handle: handle, isOwnProfile: true)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("Profile")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .task {
                guard handle == nil || handle!.isEmpty else { return }
                // ProfileService.loadMyProfile() (called by MainTabView.task) fetches both
                // /me and /me/posts in parallel. Wait for it to finish then read the handle.
                await ProfileService.shared.loadMyProfile()
                handle = ProfileService.shared.profile?.handle
            }
        }
    }
}
