import SwiftUI

struct FollowersView: View {
    @StateObject private var service = SocialService.shared

    var body: some View {
        List {
            if service.isLoading && service.followers.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if service.followers.isEmpty {
                Text("No followers yet.")
                    .foregroundColor(.secondary)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(service.followers) { user in
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
        .navigationTitle("Followers")
        .task { await service.loadFollowers() }
        .refreshable { await service.loadFollowers() }
    }
}
