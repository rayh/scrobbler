import SwiftUI
import CoreLocation

struct LocationFeedView: View {
    @StateObject private var locationService = LocationService()
    @StateObject private var locationFeedService = LocationFeedService()
    
    var body: some View {
        NavigationView {
            VStack {
                if locationService.authorizationStatus != .authorizedWhenInUse {
                    LocationPermissionView(locationService: locationService)
                } else if locationFeedService.isLoading {
                    ProgressView("Finding nearby music...")
                        .padding()
                } else if locationFeedService.nearbyPosts.isEmpty {
                    EmptyLocationView()
                } else {
                    LocationPostsList(posts: locationFeedService.nearbyPosts)
                }
            }
            .navigationTitle("Nearby Music")
            .onAppear {
                if locationService.authorizationStatus == .authorizedWhenInUse {
                    loadNearbyMusic()
                }
            }
            .onChange(of: locationService.currentLocation) { _, newLocation in
                if let location = newLocation {
                    Task {
                        await locationFeedService.loadNearbyPosts(location: location)
                    }
                }
            }
        }
    }
    
    private func loadNearbyMusic() {
        locationService.getCurrentLocation()
    }
}

struct LocationPermissionView: View {
    let locationService: LocationService
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.circle")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            
            Text("Discover Music Nearby")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("See what music people are sharing in your area")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Button("Enable Location") {
                locationService.requestLocationPermission()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct EmptyLocationView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            
            Text("No music shared nearby")
                .font(.headline)
            
            Text("Be the first to share a track in this area!")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct LocationPostsList: View {
    let posts: [LocationFeedService.LocationPost]
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(posts) { post in
                    LocationPostCard(post: post)
                }
            }
            .padding()
        }
    }
}

struct LocationPostCard: View {
    let post: LocationFeedService.LocationPost
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Album artwork
                AsyncImage(url: URL(string: post.track.artwork ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundColor(.white)
                        )
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(post.track.title)
                        .font(.headline)
                        .lineLimit(1)
                    
                    Text(post.track.artist)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    HStack {
                        Text("@\(post.userHandle)")
                            .font(.caption)
                            .foregroundColor(.blue)
                        
                        if post.nearby {
                            Text("• nearby")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Text(timeAgo(from: post.createdAt))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
            }
            
            if let comment = post.comment, !comment.isEmpty {
                Text(comment)
                    .font(.body)
                    .padding(.leading, 72)
            }
            
            if !post.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(post.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.leading, 72)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            if let urlString = post.track.appleMusicUrl,
               let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }
        }
    }
    
    private func timeAgo(from dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: dateString) else { return "" }
        
        let now = Date()
        let interval = now.timeIntervalSince(date)
        
        if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h"
        } else {
            return "\(Int(interval / 86400))d"
        }
    }
}
