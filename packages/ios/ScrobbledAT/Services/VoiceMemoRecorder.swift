import Foundation
import AVFoundation
import Speech

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
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)

    // Temp file for captured audio
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

    static func hasPermissions() async -> Bool {
        let mic = AVAudioApplication.shared.recordPermission
        if mic == .undetermined {
            return await AVAudioApplication.requestRecordPermission()
        }
        guard mic == .granted else { return false }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
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

        // Open a temp file to capture raw PCM — we'll convert to m4a on stop
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
                    self.stopEngine()
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

    // MARK: - Private

    private func stopEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioFile = nil   // flush/close the file
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
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
