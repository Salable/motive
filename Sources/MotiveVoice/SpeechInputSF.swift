import AVFoundation
import Foundation
import MotiveCore
import Speech

/// Transcribes a spoken answer on this Mac.
///
/// Three promises, each enforced by the shape of the code rather than by
/// comments: recognition is always on-device (there is no server fallback path
/// to take), no audio file is ever created (only a buffer request exists), and
/// the recognizer is torn down after every attempt (nothing keeps the
/// microphone open between answers).
///
/// Obtainable only through `MotiveVoice.makeSpeechInput`, which refuses when the
/// build cannot support it. macOS does not deny a process that asks for the
/// microphone without the right Info.plist keys — it kills it — so the check
/// must happen before the ask, and must not be skippable.
public final class SFSpeechInput: NSObject, SpeechInput, @unchecked Sendable {
    /// Stop once the transcript has been stable this long — people pause, then
    /// finish; ending on the first silence would clip them.
    static let silenceTimeout: TimeInterval = 1.2
    /// Nobody answers a yes/no question for half a minute.
    static let maxDuration: TimeInterval = 30

    private let recognizer: SFSpeechRecognizer
    private let lock = NSLock()
    private weak var sink: (any SpeechInputSink)?

    // Per-attempt state. All of it is torn down by `finish`, which is
    // idempotent and reachable from success, failure, timeout, and deinit.
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var questionID: String?
    private var transcript = ""
    private var silenceTimer: Timer?
    private var hardTimer: Timer?
    private var finished = false

    init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
        super.init()
    }

    public func setSink(_ sink: any SpeechInputSink) {
        lock.lock(); self.sink = sink; lock.unlock()
    }

    public var availability: SpeechInputAvailability {
        get async { MotiveVoice.inputAvailability() }
    }

    // MARK: listening

    public func startListening(answering questionID: String?) async {
        await requestAuthorizationIfNeeded()
        beginAttempt(answering: questionID)
    }

    public func stopListening() async {
        finish(deliver: true)
    }

    private func beginAttempt(answering questionID: String?) {
        // A fresh engine, request, and task every time: the alternative is a
        // long-lived recognizer holding the microphone between answers.
        finish(deliver: false)

        lock.lock()
        finished = false
        transcript = ""
        self.questionID = questionID
        lock.unlock()

        guard recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            // Refuse rather than fall back: server recognition would send audio
            // off this machine, which is precisely what we promise never happens.
            deliverFailure()
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        // A machine with no input device reports a zero format, and installing
        // a tap on it crashes rather than throwing.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            deliverFailure()
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.noteTranscript(result.bestTranscription.formattedString)
                if result.isFinal { self.finish(deliver: true) }
            }
            if error != nil { self.finish(deliver: true) }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        lock.lock()
        self.engine = engine
        self.request = request
        self.task = task
        lock.unlock()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            deliverFailure()
            return
        }
        scheduleHardStop()
    }

    private func noteTranscript(_ text: String) {
        lock.lock()
        transcript = text
        lock.unlock()
        scheduleSilenceStop()
    }

    private func scheduleSilenceStop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(
                withTimeInterval: Self.silenceTimeout, repeats: false
            ) { [weak self] _ in
                self?.finish(deliver: true)
            }
        }
    }

    private func scheduleHardStop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hardTimer?.invalidate()
            self.hardTimer = Timer.scheduledTimer(
                withTimeInterval: Self.maxDuration, repeats: false
            ) { [weak self] _ in
                self?.finish(deliver: true)
            }
        }
    }

    /// The single teardown path. Idempotent, because a recognition callback, a
    /// timer, and an explicit stop can all arrive for the same attempt.
    private func finish(deliver: Bool) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let engine = self.engine
        let request = self.request
        let task = self.task
        let text = transcript
        let questionID = self.questionID
        let sink = self.sink
        self.engine = nil
        self.request = nil
        self.task = nil
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.silenceTimer?.invalidate()
            self?.hardTimer?.invalidate()
            self?.silenceTimer = nil
            self?.hardTimer = nil
        }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        task?.cancel()

        guard deliver else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await sink?.transcriptDidFinalize(trimmed, answering: questionID, at: Date()) }
    }

    /// Failure resets to idle rather than retrying: the user taps the mic again
    /// if they meant to.
    private func deliverFailure() {
        finish(deliver: false)
    }

    private func requestAuthorizationIfNeeded() async {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    deinit {
        finish(deliver: false)
    }
}
