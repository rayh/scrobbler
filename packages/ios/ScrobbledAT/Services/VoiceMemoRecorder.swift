import Foundation
import AVFoundation
import Speech

/// Simple reference box so the tap closure and stopEngine() share the same AVAudioFile slot.
/// Nilling box.value from the main actor closes/flushes the file; the tap closure checks the
/// same slot and safely writes nothing after it's been cleared.
private final class AudioFileBox {
    nonisolated(unsafe) var value: AVAudioFile?
    init(_ file: AVAudioFile?) { value = file }
}

@MainActor
class VoiceMemoRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var transcript: String = ""
    @Published var recordedData: Data? = nil   // populated after recording stops
    @Published var error: String?

    private let maxRecordingDuration: TimeInterval = 10  // hard cap
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var audioFileBox: AudioFileBox?

    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)

    private var tempFileURL: URL?

    // Guard against double-stop: recognition callback and stopRecording() racing each other
    private var engineStopped = false

    static func hasPermissions() async -> Bool {
        let mic = AVAudioApplication.shared.recordPermission
        if mic == .undetermined {
            return await AVAudioApplication.requestRecordPermission()
        }
        guard mic == .granted else { return false }
        // SFSpeechRecognizer.requestAuthorization calls back on a background thread.
        // Task.detached avoids the MainActor executor assertion crash on iOS 26.
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
        transcript = ""; error = nil; recordedData = nil; engineStopped = false

        // Configure AVAudioSession for recording
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            self.error = "Could not configure audio session: \(error.localizedDescription)"
            return
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Open a temp file to capture raw PCM — we'll convert to m4a on stop
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        tempFileURL = tmp
        let file = try? AVAudioFile(forWriting: tmp, settings: format.settings)
        let box = AudioFileBox(file)
        audioFileBox = box

        // Capture request and box as nonisolated locals so the realtime audio thread
        // never touches `self` (a @MainActor object). SFSpeechAudioBufferRecognitionRequest
        // .append is thread-safe; box.value write is safe because stopEngine() only nils it
        // after removeTap() returns, guaranteeing the tap won't fire again.
        nonisolated(unsafe) let tapRequest = request
        nonisolated(unsafe) let tapBox = box
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            tapRequest.append(buffer)
            try? tapBox.value?.write(from: buffer)
        }

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in self.transcript = result.bestTranscription.formattedString }
            }
            if error != nil || result?.isFinal == true {
                Task { @MainActor in
                    // Only clean up if stopRecording() hasn't already done it
                    if !self.engineStopped {
                        self.stopEngine()
                    }
                    self.isRecording = false
                    self.isTranscribing = false
                }
            }
        }

        engine.prepare()
        do { try engine.start() } catch {
            self.error = "Could not start audio: \(error.localizedDescription)"; return
        }

        audioEngine = engine
        recognitionRequest = request
        isRecording = true

        // Auto-stop at 10s
        Task {
            try? await Task.sleep(for: .seconds(maxRecordingDuration))
            if isRecording { stopRecording() }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isTranscribing = !transcript.isEmpty
        recognitionRequest?.endAudio()
        stopEngine()
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

    // MARK: - Private

    private func stopEngine() {
        guard !engineStopped else { return }
        engineStopped = true
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioFileBox?.value = nil   // flush/close the file
        audioFileBox = nil
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Convert the captured CAF file to M4A (AAC) and store in recordedData.
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
                await MainActor.run { self.error = "Audio conversion failed: \(error.localizedDescription)" }
            }
        }
    }
}
