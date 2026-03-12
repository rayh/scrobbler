import SwiftUI
import Social
import UniformTypeIdentifiers
import CoreLocation
import NaturalLanguage
import AVFoundation
import Speech
import os.log

// MARK: - TagSuggestionService

struct TagSuggestionService {
    private static let stopwords: Set<String> = [
        "this", "that", "just", "like", "love", "great", "good", "really",
        "very", "much", "more", "some", "song", "track", "music", "album",
        "listen", "listening", "playing", "heard", "hear", "sounds", "sound",
        "feel", "feeling", "makes", "think", "know", "want", "need", "going"
    ]

    static func keywords(from text: String, limit: Int = 5) -> [String] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var frequency: [String: Int] = [:]
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .lexicalClass,
                             options: options) { tag, range in
            guard let tag, tag == .noun || tag == .adjective else { return true }
            let word = String(text[range]).lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard word.count >= 4, !stopwords.contains(word), word.allSatisfy(\.isLetter) else { return true }
            frequency[word, default: 0] += 1
            return true
        }
        return frequency.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                        .prefix(limit).map { $0.key }
    }
}

// MARK: - VoiceMemoRecorder

@MainActor
class VoiceMemoRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var transcript: String = ""
    @Published var recordedData: Data? = nil
    @Published var error: String?

    private let maxRecordingDuration: TimeInterval = 10  // hard cap
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)

    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

    static func hasPermissions() async -> Bool {
        let mic = AVAudioApplication.shared.recordPermission
        if mic == .undetermined {
            return await AVAudioApplication.requestRecordPermission()
        }
        guard mic == .granted else { return false }
        // SFSpeechRecognizer.requestAuthorization calls back on an arbitrary
        // background thread. Running the continuation from a nonisolated context
        // avoids the MainActor executor assertion crash on iOS 26.
        return await Task.detached {
            await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        }.value
    }

    func startRecording() {
        guard !isRecording else { return }
        transcript = ""; error = nil; recordedData = nil
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        tempFileURL = tmp
        audioFile = try? AVAudioFile(forWriting: tmp, settings: format.settings)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            try? self?.audioFile?.write(from: buffer)
        }
        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in self.transcript = result.bestTranscription.formattedString }
            }
            if error != nil || result?.isFinal == true {
                Task { @MainActor in
                    self.stopEngine(); self.isRecording = false; self.isTranscribing = false
                }
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            self.error = "Could not start audio: \(error.localizedDescription)"; return
        }
        audioEngine = engine; recognitionRequest = request; isRecording = true
        Task {
            try? await Task.sleep(for: .seconds(maxRecordingDuration))
            if isRecording { stopRecording() }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recognitionRequest?.endAudio()
        stopEngine()
        isRecording = false
        isTranscribing = !transcript.isEmpty
        convertAndCapture()
    }

    func clearRecording() {
        transcript = ""
        recordedData = nil
        isTranscribing = false
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    private func stopEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioFile = nil
        audioEngine = nil; recognitionRequest = nil; recognitionTask = nil
    }

    private func convertAndCapture() {
        guard let srcURL = tempFileURL else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let dstURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            do {
                let asset = AVURLAsset(url: srcURL)
                guard let exportSession = AVAssetExportSession(
                    asset: asset,
                    presetName: AVAssetExportPresetAppleM4A
                ) else { return }
                exportSession.outputURL = dstURL
                exportSession.outputFileType = .m4a
                await exportSession.export()
                let data = try Data(contentsOf: dstURL)
                try? FileManager.default.removeItem(at: srcURL)
                try? FileManager.default.removeItem(at: dstURL)
                await MainActor.run { self.recordedData = data }
            } catch {
                await MainActor.run {
                    self.error = "Audio conversion failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Location delegate for one-time location request
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

enum UploadArtworkError: Error {
    case invalidImageData
    case invalidURL
    case presignFailed
    case s3Error(Int)
    case imageConversionFailed
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
    
    override func loadView() {
        // No storyboard or nib — build the view hierarchy entirely in code
        view = UIView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        logger.info("🚀 ShareViewController viewDidLoad called")
        print("🚀 ShareViewController viewDidLoad called") // Also print to console

        // Show a loading spinner immediately so the system knows we're alive
        // (a blank view with no UI can cause the extension to be dismissed)
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.backgroundColor = .systemBackground
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

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

                // Item may arrive as URL or as a String (both happen in practice)
                let urlString: String?
                if let url = item as? URL {
                    urlString = url.absoluteString
                } else if let str = item as? String {
                    urlString = str
                } else {
                    self?.logger.error("❌ Item is not a URL or String: \(String(describing: item))")
                    self?.showError("Item is not a URL")
                    return
                }

                guard let urlString else {
                    self?.showError("Empty URL")
                    return
                }

                self?.logger.info("✅ Got URL: \(urlString)")
                Task { @MainActor in
                    await self?.handleSharedUrl(urlString)
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
            onPost: { [weak self] voiceMemoData, transcript, tags, shareLocation in
                await self?.postShare(track: track, voiceMemoData: voiceMemoData, transcript: transcript, tags: tags, shareLocation: shareLocation)
            },
            onCancel: { [weak self] in
                self?.close()
            },
            onOpenSettings: { [weak self] in
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                self?.extensionContext?.open(url, completionHandler: nil)
            }
        )

        let hostingController = UIHostingController(rootView: composerView)
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.frame = view.bounds
        hostingController.didMove(toParent: self)
    }
    
    private func postShare(track: Track, voiceMemoData: Data?, transcript: String?, tags: [String], shareLocation: Bool) async {
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
            await MainActor.run { showError("Authentication error") }
            return
        }
        
        logger.info("👤 User ID: \(userId)")
        
        do {
            // Get location if sharing is enabled
            var location: (lat: Double, lng: Double)?
            if shareLocation {
                location = await getCurrentLocation()
                logger.info("📍 Location result: \(String(describing: location))")
            }

            // Upload artwork to S3 — required, fatal on failure
            var artworkCdnUrl: String? = nil
            if let artworkUrlString = track.artworkUrl,
               let artworkUrl = URL(string: artworkUrlString) {
                logger.info("🖼️ Attempting artwork upload from: \(artworkUrlString)")
                // Throws on failure — caught by outer do/catch which shows error to user
                artworkCdnUrl = try await uploadArtwork(from: artworkUrl, idToken: idToken)
                logger.info("✅ Artwork uploaded to CDN: \(artworkCdnUrl ?? "nil")")
            } else {
                logger.warning("⚠️ No artworkUrl on track — skipping artwork upload")
            }

            // Build updated track with CDN artwork URL if we got one
            let finalTrack = artworkCdnUrl.map { cdnUrl in
                Track(
                    id: track.id,
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    isrc: track.isrc,
                    spotifyUrl: track.spotifyUrl,
                    appleMusicUrl: track.appleMusicUrl,
                    youtubeMusicUrl: track.youtubeMusicUrl,
                    sourceUrl: track.sourceUrl,
                    sourcePlatform: track.sourcePlatform,
                    artworkUrl: cdnUrl,
                    genres: track.genres
                )
            } ?? track

            // Upload voice memo to S3 if we have one — required, fatal on failure
            var voiceMemoUrl: String? = nil
            if let audioData = voiceMemoData {
                logger.info("🎙️ Uploading voice memo (\(audioData.count) bytes)...")
                let postId = "post-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
                voiceMemoUrl = try await uploadVoiceMemo(data: audioData, postId: postId, idToken: idToken)
                logger.info("✅ Voice memo uploaded to CDN: \(voiceMemoUrl ?? "nil")")
            }

            logger.info("🎵 Posting track: \(finalTrack.title) by \(finalTrack.artist)")
            
            // Post to backend
            try await shareService.postTrack(
                track: finalTrack,
                voiceMemoUrl: voiceMemoUrl,
                transcript: transcript,
                tags: tags,
                location: location,
                userId: userId,
                idToken: idToken
            )
            
            logger.info("✅ Share successful!")
            await MainActor.run { showSuccess() }
            
        } catch {
            logger.error("❌ Share failed: \(error)")
            await MainActor.run { showError(error) }
        }
    }

    /// Downloads artwork from the given URL, resizes to 1024×1024 WebP,
    /// uploads via pre-signed URL, and returns the CDN URL.
    private func uploadArtwork(from url: URL, idToken: String) async throws -> String {
        // 1. Download artwork image data
        let (imageData, _) = try await URLSession.shared.data(from: url)
        guard let image = UIImage(data: imageData) else {
            throw UploadArtworkError.invalidImageData
        }

        // 2. Resize to 1024×1024 and encode as WebP
        let webpData = try resizeToWebP(image)

        // 3. Request a pre-signed upload URL from our backend
        guard let requestUrl = URL(string: "\(Config.apiBaseUrl)/upload/request") else {
            throw UploadArtworkError.invalidURL
        }
        var uploadReq = URLRequest(url: requestUrl)
        uploadReq.httpMethod = "POST"
        uploadReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        uploadReq.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        uploadReq.httpBody = try JSONSerialization.data(withJSONObject: ["type": "post-image"])

        let (uploadResponseData, uploadResp) = try await URLSession.shared.data(for: uploadReq)
        guard let http = uploadResp as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: uploadResponseData) as? [String: Any],
              let uploadUrlString = json["uploadUrl"] as? String,
              let cdnUrlString = json["cdnUrl"] as? String,
              let s3Url = URL(string: uploadUrlString) else {
            throw UploadArtworkError.presignFailed
        }

        // 4. PUT webp data directly to S3
        var s3Req = URLRequest(url: s3Url)
        s3Req.httpMethod = "PUT"
        s3Req.setValue("image/webp", forHTTPHeaderField: "Content-Type")
        s3Req.httpBody = webpData

        let (_, s3Resp) = try await URLSession.shared.data(for: s3Req)
        guard let s3Http = s3Resp as? HTTPURLResponse, (200..<300).contains(s3Http.statusCode) else {
            let code = (s3Resp as? HTTPURLResponse)?.statusCode ?? 0
            throw UploadArtworkError.s3Error(code)
        }

        return cdnUrlString
    }

    /// Uploads voice memo M4A data via pre-signed URL and returns the CDN URL.
    private func uploadVoiceMemo(data: Data, postId: String, idToken: String) async throws -> String {
        guard let requestUrl = URL(string: "\(Config.apiBaseUrl)/upload/request") else {
            throw UploadArtworkError.invalidURL
        }
        var uploadReq = URLRequest(url: requestUrl)
        uploadReq.httpMethod = "POST"
        uploadReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        uploadReq.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        uploadReq.httpBody = try JSONSerialization.data(withJSONObject: ["type": "voice", "postId": postId])

        let (uploadResponseData, uploadResp) = try await URLSession.shared.data(for: uploadReq)
        guard let http = uploadResp as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: uploadResponseData) as? [String: Any],
              let uploadUrlString = json["uploadUrl"] as? String,
              let cdnUrlString = json["cdnUrl"] as? String,
              let s3Url = URL(string: uploadUrlString) else {
            throw UploadArtworkError.presignFailed
        }

        var s3Req = URLRequest(url: s3Url)
        s3Req.httpMethod = "PUT"
        s3Req.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")
        s3Req.httpBody = data

        let (_, s3Resp) = try await URLSession.shared.data(for: s3Req)
        guard let s3Http = s3Resp as? HTTPURLResponse, (200..<300).contains(s3Http.statusCode) else {
            let code = (s3Resp as? HTTPURLResponse)?.statusCode ?? 0
            throw UploadArtworkError.s3Error(code)
        }

        return cdnUrlString
    }

    private func resizeToWebP(_ image: UIImage) throws -> Data {
        let targetSize = CGSize(width: 1024, height: 1024)
        let side = min(image.size.width, image.size.height)
        let origin = CGPoint(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2)
        let cropRect = CGRect(origin: origin, size: CGSize(width: side, height: side))
        guard let cgCropped = image.cgImage?.cropping(to: cropRect) else {
            throw UploadArtworkError.invalidImageData
        }
        let cropped = UIImage(cgImage: cgCropped)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in cropped.draw(in: CGRect(origin: .zero, size: targetSize)) }
        guard let cgImage = resized.cgImage else { throw UploadArtworkError.invalidImageData }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, "public.webp" as CFString, 1, nil
        ) else { throw UploadArtworkError.imageConversionFailed }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw UploadArtworkError.imageConversionFailed }
        return mutableData as Data
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
    let onPost: (Data?, String?, [String], Bool) async -> Void
    let onCancel: () -> Void
    var onOpenSettings: (() -> Void)? = nil

    @StateObject private var voiceRecorder = VoiceMemoRecorder()
    @State private var shareLocation = true
    @State private var isPosting = false
    @State private var isPlayingBack = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var micPermissionDenied = false

    // Tags are auto-extracted from transcript — never shown to user
    private var autoTags: [String] {
        let nlpTags = voiceRecorder.transcript.isEmpty
            ? []
            : TagSuggestionService.keywords(from: voiceRecorder.transcript)
        let genreTags = (track.genres ?? [])
            .flatMap { $0.components(separatedBy: "/") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "") }
            .filter { !$0.isEmpty && $0 != "music" }
        return Array(Set(nlpTags + genreTags))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {

                    // ── Track card ────────────────────────────────────────────
                    HStack(spacing: 16) {
                        AsyncImage(url: URL(string: track.artworkUrl ?? "")) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(LinearGradient(colors: [.blue, .purple],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay(Image(systemName: "music.note").font(.title).foregroundColor(.white))
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).font(.headline).fontWeight(.semibold).lineLimit(2)
                            Text(track.artist).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                            if let album = track.album {
                                Text(album).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(20)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                    // ── Voice intro ───────────────────────────────────────────
                    VStack(spacing: 16) {
                        Text("Add a voice intro")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if micPermissionDenied {
                            // Permission denied — link to Settings
                            VStack(spacing: 10) {
                                Image(systemName: "mic.slash.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.secondary)
                                Text("Microphone access is required to record a voice intro.")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Open Settings") {
                                    onOpenSettings?()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 16))

                        } else if voiceRecorder.recordedData == nil {
                            // Hold-to-record button
                            VStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(voiceRecorder.isRecording ? Color.red : Color.accentColor)
                                        .frame(width: 80, height: 80)
                                        .scaleEffect(voiceRecorder.isRecording ? 1.15 : 1.0)
                                        .animation(.easeInOut(duration: 0.15), value: voiceRecorder.isRecording)
                                    Image(systemName: voiceRecorder.isRecording ? "stop.fill" : "mic.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(.white)
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { _ in
                                            if !voiceRecorder.isRecording {
                                                voiceRecorder.startRecording()
                                            }
                                        }
                                        .onEnded { _ in
                                            if voiceRecorder.isRecording {
                                                voiceRecorder.stopRecording()
                                            }
                                        }
                                )

                                if voiceRecorder.isRecording {
                                    HStack(spacing: 6) {
                                        Image(systemName: "waveform")
                                            .foregroundColor(.red)
                                            .symbolEffect(.pulse)
                                        Text("Recording… release to stop (10s max)")
                                            .font(.caption)
                                            .foregroundColor(.red)
                                    }
                                } else {
                                    Text("Hold to record · 10 seconds max")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 16))

                        } else {
                            // Recorded — transcript preview + playback/delete
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    Text("Intro recorded").font(.subheadline).fontWeight(.medium)
                                    Spacer()
                                    Button {
                                        audioPlayer?.stop(); audioPlayer = nil
                                        isPlayingBack = false
                                        voiceRecorder.clearRecording()
                                    } label: {
                                        Image(systemName: "trash").foregroundColor(.red)
                                    }
                                }
                                if !voiceRecorder.transcript.isEmpty {
                                    Text("\"\(voiceRecorder.transcript)\"")
                                        .font(.footnote).foregroundColor(.secondary)
                                        .italic().lineLimit(3)
                                }
                                HStack(spacing: 12) {
                                    Button { togglePlayback() } label: {
                                        Label(isPlayingBack ? "Stop" : "Play",
                                              systemImage: isPlayingBack ? "stop.circle" : "play.circle")
                                            .font(.subheadline).fontWeight(.medium)
                                    }
                                    .buttonStyle(.bordered)

                                    Button {
                                        audioPlayer?.stop(); audioPlayer = nil
                                        isPlayingBack = false
                                        voiceRecorder.clearRecording()
                                    } label: {
                                        Label("Re-record", systemImage: "arrow.counterclockwise")
                                            .font(.subheadline)
                                    }
                                    .foregroundColor(.secondary)
                                }
                            }
                            .padding(16)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Share Track")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Request mic permission immediately — no point waiting for tap
                Task {
                    let ok = await VoiceMemoRecorder.hasPermissions()
                    if !ok { micPermissionDenied = true }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }.disabled(isPosting)
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    // Location icon toggle — compact, no label
                    Button {
                        shareLocation.toggle()
                    } label: {
                        Image(systemName: shareLocation ? "location.fill" : "location.slash")
                            .foregroundColor(shareLocation ? .blue : .secondary)
                    }
                    .help(shareLocation ? "Location on" : "Location off")

                    Button {
                        Task {
                            isPosting = true
                            await onPost(
                                voiceRecorder.recordedData,
                                voiceRecorder.transcript.isEmpty ? nil : voiceRecorder.transcript,
                                autoTags,
                                shareLocation
                            )
                        }
                    } label: {
                        if isPosting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Share").fontWeight(.semibold)
                        }
                    }
                    .disabled(isPosting)
                }
            }
        }
    }

    private func togglePlayback() {
        guard let data = voiceRecorder.recordedData else { return }
        if isPlayingBack {
            audioPlayer?.stop(); audioPlayer = nil; isPlayingBack = false
        } else {
            do {
                audioPlayer = try AVAudioPlayer(data: data)
                audioPlayer?.play()
                isPlayingBack = true
                Task {
                    let duration = audioPlayer?.duration ?? 0
                    try? await Task.sleep(for: .seconds(duration + 0.1))
                    isPlayingBack = false
                }
            } catch {
                isPlayingBack = false
            }
        }
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
        onPost: { _, _, _, _ in },
        onCancel: {}
    )
}
