import SwiftUI
import Social
import UniformTypeIdentifiers
import CoreLocation
import os.log

// Location delegate for one-time location request
class LocationDelegate: NSObject, CLLocationManagerDelegate {
    private let completion: ((lat: Double, lng: Double)?) -> Void
    private var didFire = false

    init(completion: @escaping ((lat: Double, lng: Double)?) -> Void) {
        self.completion = completion
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !didFire else { return }
        didFire = true
        manager.stopUpdatingLocation()
        if let location = locations.first {
            completion((lat: location.coordinate.latitude, lng: location.coordinate.longitude))
        } else {
            completion(nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard !didFire else { return }
        didFire = true
        manager.stopUpdatingLocation()
        completion(nil)
    }
}

// Share Extension view controller
class ShareViewController: UIViewController {
    private let metadataService = MusicMetadataService()
    
    private func getKeychainToken(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "net.wirestorm.scrobbler",
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: "group.net.wirestorm.scrobbler",
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return string
    }
    private let shareService = ShareExtensionService()
    private let logger = Logger(subsystem: "net.wirestorm.scrobbler.ShareExtension", category: "ShareViewController")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        logger.info("🚀 ShareViewController viewDidLoad called")
        print("🚀 ShareViewController viewDidLoad called") // Also print to console
        
        processSharedContent()
    }
    
    private func processSharedContent() {
        logger.info("📦 Processing shared content...")
        
        // Extract shared content
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem else {
            logger.error("❌ No extension items found")
            showError("No content found to share")
            return
        }
        
        logger.info("📦 Extension item: \(extensionItem)")
        logger.info("📦 Attachments count: \(extensionItem.attachments?.count ?? 0)")
        
        guard let itemProvider = extensionItem.attachments?.first else {
            logger.error("❌ No attachments found")
            showError("No attachments found")
            return
        }
        
        logger.info("📦 Item provider: \(itemProvider)")
        logger.info("📦 Registered type identifiers: \(itemProvider.registeredTypeIdentifiers)")
        
        // Try URL first
        if itemProvider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            logger.info("🔗 Found URL type, loading...")
            itemProvider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] (item, error) in
                if let error = error {
                    self?.logger.error("❌ URL load error: \(error)")
                    self?.showError("URL load error: \(error.localizedDescription)")
                    return
                }
                
                guard let url = item as? URL else {
                    self?.logger.error("❌ Item is not a URL: \(String(describing: item))")
                    self?.showError("Item is not a URL")
                    return
                }
                
                self?.logger.info("✅ Got URL: \(url.absoluteString)")
                Task { @MainActor in
                    await self?.handleSharedUrl(url.absoluteString)
                }
            }
        }
        // Try text (for copied links)
        else if itemProvider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            logger.info("📝 Found text type, loading...")
            itemProvider.loadItem(forTypeIdentifier: UTType.text.identifier) { [weak self] (item, error) in
                if let error = error {
                    self?.logger.error("❌ Text load error: \(error)")
                    self?.showError("Text load error: \(error.localizedDescription)")
                    return
                }
                
                guard let text = item as? String else {
                    self?.logger.error("❌ Item is not text: \(String(describing: item))")
                    self?.showError("Item is not text")
                    return
                }
                
                self?.logger.info("✅ Got text: \(text)")
                Task { @MainActor in
                    await self?.handleSharedUrl(text)
                }
            }
        }
        else {
            logger.error("❌ No supported type found. Available types: \(itemProvider.registeredTypeIdentifiers)")
            showError("No URL or text found. Available types: \(itemProvider.registeredTypeIdentifiers.joined(separator: ", "))")
        }
    }
    
    private func showError(_ message: String) {
        logger.error("🚨 Showing error: \(message)")
        DispatchQueue.main.async { [weak self] in
            let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                self?.close()
            })
            self?.present(alert, animated: true)
        }
    }
    
    private func handleSharedUrl(_ urlString: String) async {
        logger.info("🔗 Handling shared URL: \(urlString)")
        
        do {
            logger.info("🎵 Starting metadata extraction...")
            let track = try await metadataService.extractMetadata(from: urlString)
            logger.info("✅ Metadata extracted successfully: \(track.title) by \(track.artist)")
            
            await MainActor.run {
                showComposer(with: track)
            }
        } catch {
            logger.error("❌ Metadata extraction failed: \(error)")
            await MainActor.run {
                let errorMsg = "Failed to extract track info: \(error.localizedDescription)\n\nURL: \(urlString)"
                showError(errorMsg)
            }
        }
    }
    
    private func showComposer(with track: Track) {
        let composerView = ShareComposerView(
            track: track,
            onPost: { [weak self] comment, tags, shareLocation in
                await self?.postShare(track: track, comment: comment, tags: tags, shareLocation: shareLocation)
            },
            onCancel: { [weak self] in
                self?.close()
            }
        )
        
        let hostingController = UIHostingController(rootView: composerView)
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.frame = view.bounds
        hostingController.didMove(toParent: self)
    }
    
    private func postShare(track: Track, comment: String?, tags: [String], shareLocation: Bool) async {
        logger.info("🚀 Starting postShare...")
        
        // Get JWT from Keychain
        guard let idToken = getKeychainToken(key: "idToken") else {
            logger.error("❌ No authentication token found")
            await MainActor.run {
                let alert = UIAlertController(
                    title: "Not Signed In",
                    message: "Please open the Selector app and sign in first.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                    self?.close()
                })
                present(alert, animated: true)
            }
            return
        }
        
        // Decode JWT to get userId
        guard let userInfo = decodeJWT(idToken),
              let userId = userInfo["sub"] as? String else {
            logger.error("❌ Failed to decode JWT")
            await MainActor.run {
                showError("Authentication error")
            }
            return
        }
        
        logger.info("👤 User ID: \(userId)")
        
        do {
            logger.info("📍 Getting location (shareLocation: \(shareLocation))...")
            
            // Get location if sharing is enabled
            var location: (lat: Double, lng: Double)?
            if shareLocation {
                location = await getCurrentLocation()
                logger.info("📍 Location result: \(String(describing: location))")
            }
            
            logger.info("🎵 Posting track: \(track.title) by \(track.artist)")
            
            // Post to backend
            try await shareService.postTrack(
                track: track,
                comment: comment,
                tags: tags,
                location: location,
                userId: userId,
                idToken: idToken
            )
            
            logger.info("✅ Share successful!")
            
            await MainActor.run {
                showSuccess()
            }
            
        } catch {
            logger.error("❌ Share failed: \(error)")
            await MainActor.run {
                showError(error)
            }
        }
    }
    
    // Retained for the duration of the location request
    private var locationManager: CLLocationManager?
    private var locationDelegate: LocationDelegate?

    private func getCurrentLocation() async -> (lat: Double, lng: Double)? {
        return await withCheckedContinuation { continuation in
            let manager = CLLocationManager()
            let delegate = LocationDelegate { [weak self] location in
                self?.locationManager = nil
                self?.locationDelegate = nil
                continuation.resume(returning: location)
            }
            manager.delegate = delegate
            // Retain both until the callback fires
            self.locationManager = manager
            self.locationDelegate = delegate

            // Only request if we already have permission — don't prompt from extension
            let status = manager.authorizationStatus
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            } else {
                // No permission — resume immediately with nil rather than hanging
                self.locationManager = nil
                self.locationDelegate = nil
                continuation.resume(returning: nil)
            }
        }
    }
    
    private func showSuccess() {
        let alert = UIAlertController(title: "Shared!", message: "Your track has been shared with your followers.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak self] _ in
            self?.close()
        })
        present(alert, animated: true)
    }
    
    private func showError(_ error: Error) {
        let message: String
        if let musicError = error as? MusicError {
            message = musicError.localizedDescription
        } else {
            message = "Error: \(error.localizedDescription)\n\nDetails: \(error)"
        }
        
        let alert = UIAlertController(
            title: "Error",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.close()
        })
        present(alert, animated: true)
    }
    
    private func decodeJWT(_ token: String) -> [String: Any]? {
        let segments = token.components(separatedBy: ".")
        guard segments.count > 1 else { return nil }
        
        var base64 = segments[1]
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        return json
    }
    
    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

// SwiftUI composer view
struct ShareComposerView: View {
    let track: Track
    let onPost: (String?, [String], Bool) async -> Void
    let onCancel: () -> Void
    
    @State private var comment = ""
    @State private var tags: [String] = []
    @State private var tagInput = ""
    @State private var shareLocation = true
    @State private var isPosting = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Track preview card
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        AsyncImage(url: URL(string: track.artworkUrl ?? "")) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.title)
                                        .foregroundColor(.white)
                                )
                        }
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(.headline)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                            
                            Text(track.artist)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            
                            if let album = track.album {
                                Text(album)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        
                        Spacer()
                    }
                }
                .padding(20)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                
                // Comment section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("What do you think?")
                            .font(.headline)
                        Spacer()
                        Text("\(comment.count)/280")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    TextField("Share your thoughts about this track...", text: $comment, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(4...8)
                        .padding(16)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                
                // Location toggle
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "location")
                            .foregroundColor(.blue)
                        Text("Share approximate location")
                            .font(.subheadline)
                        Spacer()
                        Toggle("", isOn: $shareLocation)
                    }
                    .padding(.horizontal, 20)
                    
                    if shareLocation {
                        Text("Others nearby can discover this track")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 16)
                
                // Tags section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tags")
                        .font(.headline)
                    
                    // Tag input
                    HStack {
                        TextField("Add a tag", text: $tagInput)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .onSubmit {
                                addTag()
                            }
                        
                        Button("Add") {
                            addTag()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    
                    // Current tags
                    if !tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(tags, id: \.self) { tag in
                                    HStack(spacing: 6) {
                        Text("#\(tag)")
                                        Button {
                                            tags.removeAll { $0 == tag }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption)
                                        }
                                    }
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.1))
                                    .foregroundColor(.blue)
                                    .clipShape(Capsule())
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    
                    // Suggested tags
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestedTags, id: \.self) { tag in
                                Button("#\(tag)") {
                                    tags.append(tag)
                                }
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray5))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                
                Spacer()
            }
            .navigationTitle("Share Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .disabled(isPosting)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isPosting = true
                            await onPost(
                                comment.isEmpty ? nil : comment,
                                tags,
                                shareLocation
                            )
                        }
                    } label: {
                        if isPosting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Share")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isPosting)
                }
            }
        }
    }
    
    private func addTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, !tags.contains(trimmed), tags.count < 5 else { return }
        tags.append(trimmed)
        tagInput = ""
    }
    
    private var suggestedTags: [String] {
        let all = ["chill", "workout", "focus", "party", "morning", "evening", "driving", "study"]
        return all.filter { !tags.contains($0) }.prefix(4).map { $0 }
    }
}

#Preview {
    ShareComposerView(
        track: Track(
            id: "1",
            title: "Song Title",
            artist: "Artist Name",
            album: "Album Name",
            isrc: nil,
            sourceUrl: "",
            sourcePlatform: .spotify,
            artworkUrl: nil
        ),
        onPost: { _, _, _ in },
        onCancel: {}
    )
}
