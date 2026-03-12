import SwiftUI

struct FollowingView: View {
    @StateObject private var service = SocialService.shared

    var body: some View {
        List {
            if service.isLoading && service.following.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if service.following.isEmpty {
                Text("You're not following anyone yet.")
                    .foregroundColor(.secondary)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(service.following) { user in
                    NavigationLink(destination: UserProfileView(handle: user.handle)) {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Text(String(user.handle.first ?? "?").uppercased())
                                        .foregroundColor(.white)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                )

                            Text("@\(user.handle)")
                                .font(.body)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Following")
        .task { await service.loadFollowing() }
        .refreshable { await service.loadFollowing() }
    }
}
