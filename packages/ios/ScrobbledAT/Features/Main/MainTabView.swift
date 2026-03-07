import SwiftUI
import PhotosUI
import CoreLocation

struct MainTabView: View {
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
            
            NavigationView {
                VStack {
                    Text("Music Sharing")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Share your favorite tracks from Apple Music")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Spacer()
                }
                .padding()
                .navigationTitle("Share")
            }
            .tabItem {
                Image(systemName: "plus.circle")
                Text("Share")
            }
            
            ProfileView()
                .tabItem {
                    Image(systemName: "person.circle")
                    Text("Profile")
                }
        }
    }
}

// MARK: - ProfileView

struct ProfileView: View {
    @EnvironmentObject var appleSignInService: AppleSignInService
    @StateObject private var profileService = ProfileService.shared
    @StateObject private var locationService = LocationService()

    @State private var showingAvatarPicker = false
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var showingEditBio = false
    @State private var editingBio = ""

    var body: some View {
        NavigationView {
            List {
                // MARK: Profile header section
                Section {
                    HStack(spacing: 16) {
                        avatarView
                            .onTapGesture { showingAvatarPicker = true }

                        VStack(alignment: .leading, spacing: 2) {
                            if let profile = profileService.profile {
                                if let name = profile.name {
                                    Text(name)
                                        .font(.headline)
                                }
                                Text("@\(profile.handle)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                if let loc = profile.location?.displayString {
                                    Label(loc, systemImage: "mappin.and.ellipse")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else if let user = appleSignInService.currentUser {
                                Text(user.name ?? "")
                                    .font(.headline)
                                Text("@\(user.handle ?? "")")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        if profileService.isUploadingAvatar {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                    .padding(.vertical, 4)

                    // Bio
                    if let bio = profileService.profile?.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }

                    Button {
                        editingBio = profileService.profile?.bio ?? ""
                        showingEditBio = true
                    } label: {
                        Label("Edit Profile", systemImage: "pencil")
                            .font(.subheadline)
                    }
                }

                // MARK: Social section
                Section("Social") {
                    NavigationLink(destination: FollowingView()) {
                        Label("Following", systemImage: "person.2")
                    }
                }

                // MARK: Sign Out
                if appleSignInService.isAuthenticated {
                    Section {
                        Button(role: .destructive) {
                            appleSignInService.signOut()
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
            .navigationTitle("Profile")
            .task {
                await profileService.loadMyProfile()
                await captureLocationIfNeeded()
            }
            // Avatar picker
            .photosPicker(
                isPresented: $showingAvatarPicker,
                selection: $selectedPhoto,
                matching: .images
            )
            .onChange(of: selectedPhoto) { newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        await profileService.uploadAvatar(data)
                    }
                    selectedPhoto = nil
                }
            }
            // Edit bio sheet
            .sheet(isPresented: $showingEditBio) {
                EditBioSheet(bio: $editingBio) { saved in
                    if saved {
                        Task {
                            await profileService.updateProfile(bio: editingBio.isEmpty ? nil : editingBio)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let avatarUrl = profileService.profile?.avatarUrl,
                   let url = URL(string: avatarUrl) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        initialsCircle
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                } else {
                    initialsCircle
                }
            }

            Image(systemName: "camera.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .padding(4)
                .background(Color.blue)
                .clipShape(Circle())
                .offset(x: 2, y: 2)
        }
        .frame(width: 56, height: 56)
    }

    private var initialsCircle: some View {
        let initial: String = {
            if let profile = profileService.profile {
                return String(profile.name?.first ?? profile.handle.first ?? "?").uppercased()
            }
            if let user = appleSignInService.currentUser {
                return String(user.name?.first ?? user.handle?.first ?? "?").uppercased()
            }
            return "?"
        }()
        return Circle()
            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 56, height: 56)
            .overlay(
                Text(initial)
                    .foregroundColor(.white)
                    .font(.title2)
                    .fontWeight(.medium)
            )
    }

    /// Request location permission, reverse-geocode to city/country, and save to profile.
    /// Only runs when the profile has no location set yet, to avoid hammering the API.
    private func captureLocationIfNeeded() async {
        // Only capture if profile loaded but has no location
        guard profileService.profile?.location == nil else { return }

        // Request permission if not yet determined
        let status = locationService.authorizationStatus
        if status == .notDetermined {
            locationService.requestLocationPermission()
            // Give the OS a moment to show the dialog; user may deny
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        guard locationService.authorizationStatus == CLAuthorizationStatus.authorizedWhenInUse
                || locationService.authorizationStatus == CLAuthorizationStatus.authorizedAlways else { return }

        locationService.getCurrentLocation()

        // Wait up to 5 seconds for location to arrive
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if locationService.currentLocation != nil { break }
        }

        guard let clLocation = locationService.currentLocation else { return }
        guard let loc = await profileService.reverseGeocodeCurrentLocation(clLocation) else { return }
        await profileService.updateProfile(location: loc)
    }
}

// MARK: - Edit Bio Sheet

struct EditBioSheet: View {
    @Binding var bio: String
    let onDismiss: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("Bio") {
                    TextEditor(text: $bio)
                        .frame(minHeight: 80)
                }
                Section {
                    Text("\(bio.count)/160 characters")
                        .font(.caption)
                        .foregroundColor(bio.count > 160 ? .red : .secondary)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss(false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onDismiss(true)
                        dismiss()
                    }
                    .disabled(bio.count > 160)
                }
            }
        }
    }
}
