import AVFoundation
import Foundation
import MotiveCore

/// Maps a user-facing speed multiplier to AVSpeechUtterance's own scale.
///
/// The raw AV rate is meaningless to a person (0.5 is "normal"), so settings
/// speak in multiples of normal and this converts.
enum RateMapping {
    static let defaultMultiplier: Double = 1.0
    static let minMultiplier: Double = 0.5
    static let maxMultiplier: Double = 2.0

    static func avRate(for multiplier: Double?) -> Float {
        let clamped = min(max(multiplier ?? defaultMultiplier, minMultiplier), maxMultiplier)
        let normal = Double(AVSpeechUtteranceDefaultSpeechRate)
        // Below normal, interpolate toward the engine minimum; above, toward
        // the maximum. Linear in each half keeps 1.0 exactly normal.
        if clamped <= defaultMultiplier {
            let low = Double(AVSpeechUtteranceMinimumSpeechRate)
            let t = (clamped - minMultiplier) / (defaultMultiplier - minMultiplier)
            return Float(low + (normal - low) * t)
        }
        let high = Double(AVSpeechUtteranceMaximumSpeechRate)
        let t = (clamped - defaultMultiplier) / (maxMultiplier - defaultMultiplier)
        return Float(normal + (high - normal) * t)
    }
}

/// The installed voices, by display name.
public enum VoiceCatalog {
    public static func availableVoiceNames() -> [String] {
        AVSpeechSynthesisVoice.speechVoices()
            .map(\.name)
            .reduce(into: [String]()) { unique, name in
                if !unique.contains(name) { unique.append(name) }
            }
            .sorted()
    }

    /// Resolve defensively: a stored setting can outlive the voice it names
    /// (the user uninstalled it), and the right answer is the system default
    /// plus a visible diagnostic — never silence, never a crash.
    static func voice(named name: String?) -> AVSpeechSynthesisVoice? {
        guard let name, !name.isEmpty else { return nil }
        return AVSpeechSynthesisVoice.speechVoices().first { $0.name == name }
    }
}

/// Speaks through `AVSpeechSynthesizer`, in-process.
///
/// No sidecar: the reference implementation this borrows from needed one only
/// because its host app was Zig and could not call AVFoundation. We can, so the
/// spool files, status protocol, and supervisor all disappear.
public final class AVSpeechOutput: NSObject, SpeechOutput, AVSpeechSynthesizerDelegate,
    @unchecked Sendable
{
    /// One synthesizer for the process lifetime — churning them is a known
    /// source of leaks and crashes.
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private weak var sink: (any SpeechOutputSink)?
    /// id of the utterance currently owned by each AVSpeechUtterance we made,
    /// so a late callback can be matched rather than guessed at.
    private var idsByUtterance: [ObjectIdentifier: String] = [:]
    /// Ids we have already reported. Every stop produces a cancel callback that
    /// can arrive *after* the queue moved on; without this, a stale cancel
    /// would complete the next line instead.
    private var reported: Set<String> = []
    private var lastFailure: String?

    public init(sink: (any SpeechOutputSink)? = nil) {
        super.init()
        self.sink = sink
        synthesizer.delegate = self
    }

    public func setSink(_ sink: any SpeechOutputSink) {
        lock.lock(); self.sink = sink; lock.unlock()
    }

    /// Installed voices, newest resolution each call so an uninstall is seen.
    public func availableVoiceNames() -> [String] { VoiceCatalog.availableVoiceNames() }

    /// Why the last utterance failed, for the diagnostics pane.
    public var lastFailureReason: String? {
        lock.lock(); defer { lock.unlock() }
        return lastFailure
    }

    // MARK: SpeechOutput

    public func speak(_ utterance: SpeechUtterance) async {
        prepareAndSpeak(utterance)
    }

    /// Synchronous so the lock is never taken from an async context.
    private func prepareAndSpeak(_ utterance: SpeechUtterance) {
        let av = AVSpeechUtterance(string: utterance.text)
        av.rate = RateMapping.avRate(for: utterance.rate)
        var failure: String?
        if let voice = VoiceCatalog.voice(named: utterance.voiceID) {
            av.voice = voice
        } else if let requested = utterance.voiceID, !requested.isEmpty {
            // Never silence, never a crash: fall back to the system voice and
            // make the reason visible in diagnostics.
            failure = "voice “\(requested)” is not installed; using the system default"
        }
        lock.lock()
        lastFailure = failure
        idsByUtterance[ObjectIdentifier(av)] = utterance.id
        lock.unlock()
        synthesizer.speak(av)
    }

    public func stop(graceful: Bool) async {
        synthesizer.stopSpeaking(at: graceful ? .word : .immediate)
    }

    public func pause() async {
        synthesizer.pauseSpeaking(at: .word)
    }

    public func resume() async {
        synthesizer.continueSpeaking()
    }

    public var isAvailable: Bool {
        get async { hasUsableVoice() }
    }

    private func hasUsableVoice() -> Bool { !AVSpeechSynthesisVoice.speechVoices().isEmpty }

    // MARK: AVSpeechSynthesizerDelegate

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        guard let id = identifier(for: utterance) else { return }
        let sink = currentSink()
        Task { await sink?.speechDidStart(id: id, at: Date()) }
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        finish(utterance, outcome: .finished)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        finish(utterance, outcome: .cancelled)
    }

    // MARK: internals

    private func finish(_ utterance: AVSpeechUtterance, outcome: SpeechOutcome) {
        lock.lock()
        let key = ObjectIdentifier(utterance)
        guard let id = idsByUtterance.removeValue(forKey: key), !reported.contains(id) else {
            lock.unlock()
            return
        }
        reported.insert(id)
        if reported.count > 64 { reported.removeFirst() }
        let sink = self.sink
        lock.unlock()
        Task { await sink?.speechDidFinish(id: id, outcome: outcome, at: Date()) }
    }

    private func identifier(for utterance: AVSpeechUtterance) -> String? {
        lock.lock(); defer { lock.unlock() }
        return idsByUtterance[ObjectIdentifier(utterance)]
    }

    private func currentSink() -> (any SpeechOutputSink)? {
        lock.lock(); defer { lock.unlock() }
        return sink
    }
}
