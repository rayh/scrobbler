import SwiftUI
import CoreLocation

struct LocationFeedView: View {
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var locationFeedService: LocationFeedService
    @EnvironmentObject var feedService: FeedService

    var body: some View {
        NavigationView {
            Group {
                if locationService.authorizationStatus != .authorizedWhenInUse
                    && locationService.authorizationStatus != .authorizedAlways {
                    LocationPermissionView(locationService: locationService)
                } else if locationFeedService.isLoading && locationFeedService.nearbyPosts.isEmpty {
                    ProgressView("Finding nearby music...")
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if locationFeedService.nearbyPosts.isEmpty {
                    EmptyLocationView()
                } else {
                    List {
                        ForEach(locationFeedService.nearbyPosts.map { $0.asFeedGroup }) { group in
                            FeedPostCell(group: group, showUser: true)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        }
                    }
                    .listStyle(PlainListStyle())
                    .refreshable {
                        locationService.getCurrentLocation()
                    }
                }
            }
            .navigationTitle("Nearby Music")
            .onAppear {
                let status = locationService.authorizationStatus
                if status == .authorizedWhenInUse || status == .authorizedAlways {
                    locationService.getCurrentLocation()
                }
            }
            .onChange(of: locationService.authorizationStatus) { _, status in
                // Only trigger when permission transitions from denied/undetermined to granted
                // (i.e. user just granted permission in the system prompt while view was visible).
                // onAppear already handles the case where permission was granted before the view loaded.
                guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
                guard locationFeedService.nearbyPosts.isEmpty else { return }
                locationService.getCurrentLocation()
            }
            .onChange(of: locationService.currentLocation) { _, newLocation in
                if let location = newLocation {
                    Task { await locationFeedService.loadNearbyPosts(location: location) }
                }
            }
        }
    }
}

// MARK: - Subviews

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

// MARK: - LocationPost → FeedGroup conversion

extension LocationFeedService.LocationPost {
    var asFeedGroup: FeedService.FeedGroup {
        FeedService.FeedGroup(
            groupId: postId,
            trackKey: nil,
            track: FeedService.FeedGroup.TrackInfo(
                id: track.id,
                title: track.title,
                artist: track.artist,
                album: track.album,
                artwork: track.artwork,
                appleMusicUrl: track.appleMusicUrl,
                spotifyUrl: nil
            ),
            windowStart: createdAt,
            lastUpdatedAt: createdAt,
            sharedBy: [
                FeedService.FeedGroup.SharedByEntry(
                    postId: postId,
                    userId: userId,
                    userHandle: userHandle,
                    voiceMemoUrl: nil,
                    transcript: comment,
                    tags: tags,
                    createdAt: createdAt
                )
            ],
            likes: 0,
            location: location.map {
                FeedService.FeedGroup.LocationInfo(
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    hex: $0.hex
                )
            }
        )
    }
}
