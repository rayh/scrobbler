import SwiftUI

// MARK: - Deep link router

@MainActor
class AppRouter: ObservableObject {
    @Published var pendingProfileHandle: String?

    func handle(url: URL) {
        // Universal link: https://<host>/u/<handle>
        if url.scheme == "https" || url.scheme == "http" {
            let components = url.pathComponents
            if components.count >= 3, components[1] == "u" {
                pendingProfileHandle = components[2]
                return
            }
        }
        // Custom scheme: slctr://profile/<handle>
        if url.scheme == "slctr", url.host == "profile" {
            pendingProfileHandle = url.pathComponents.dropFirst().first
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var appleSignInService = AppleSignInService()
    @StateObject private var feedService = FeedService()
    @StateObject private var locationService = LocationService()
    @StateObject private var router = AppRouter()
    @EnvironmentObject var pushService: PushNotificationService

    var body: some View {
        Group {
            if appleSignInService.isAuthenticated {
                MainTabView()
                    .environmentObject(appleSignInService)
                    .environmentObject(feedService)
                    .environmentObject(locationService)
                    .environmentObject(pushService)
                    .environmentObject(router)
            } else {
                OnboardingView()
                    .environmentObject(appleSignInService)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .forceLogout)) { _ in
            appleSignInService.signOut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openURL)) { notification in
            if let url = notification.object as? URL {
                router.handle(url: url)
            }
        }
        // Present profile sheet when a deep link arrives
        .sheet(item: Binding(
            get: { router.pendingProfileHandle.map { DeepLinkHandle(handle: $0) } },
            set: { if $0 == nil { router.pendingProfileHandle = nil } }
        )) { item in
            NavigationView {
                UserProfileView(handle: item.handle, isModal: true) {
                    router.pendingProfileHandle = nil
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { router.pendingProfileHandle = nil }
                    }
                }
            }
        }
    }
}

/// Helper Identifiable wrapper so .sheet(item:) works with a String.
private struct DeepLinkHandle: Identifiable {
    let handle: String
    var id: String { handle }
}
