import Foundation

/// Voice settings a sprite package may declare, so a pet sounds like itself on
/// any host app. Plain data in Core — `MotiveSprite` decodes it, `MotiveVoice`
/// consumes it, and a user's own setting overrides it.
public struct VoicePreferences: Codable, Equatable, Sendable {
    /// Implementation-defined voice identifier or display name.
    public let voiceID: String?
    /// Speed multiplier, 1.0 == normal.
    public let rate: Double?
    /// Which state means "talking", so the mouth moves for exactly the audio.
    public let talkingState: String?

    public init(voiceID: String? = nil, rate: Double? = nil, talkingState: String? = nil) {
        self.voiceID = voiceID
        self.rate = rate
        self.talkingState = talkingState
    }
}

/// One thing to say aloud. `id` is the queue item's id, so completion routes
/// back to exactly the item that is waiting.
public struct SpeechUtterance: Equatable, Sendable {
    public let id: String
    public let text: String
    /// Implementation-defined voice identifier; nil uses the system default.
    public let voiceID: String?
    /// User-facing speed multiplier (1.0 == normal); nil uses the default.
    public let rate: Double?

    public init(id: String, text: String, voiceID: String? = nil, rate: Double? = nil) {
        self.id = id
        self.text = text
        self.voiceID = voiceID
        self.rate = rate
    }
}

/// How an utterance ended.
public enum SpeechOutcome: Equatable, Sendable {
    case finished
    /// Stopped early — skip, flush, or a new utterance taking over.
    case cancelled
    /// Never played, or the audio route failed. Distinct from `finished` on
    /// purpose: a silent queue must not be able to masquerade as a spoken one.
    case failed(reason: String)
}

/// Somewhere text can be spoken aloud.
///
/// Deliberately free of any audio-framework type: `MotiveCore` never learns
/// that AVFoundation exists, tests inject a fake that completes on command, and
/// an out-of-process implementation could be dropped in later without changing
/// the framework surface.
public protocol SpeechOutput: Sendable {
    /// Begin speaking. Fire-and-forget — results arrive through the sink.
    func speak(_ utterance: SpeechUtterance) async
    /// Stop the current utterance. `graceful` finishes the current word.
    func stop(graceful: Bool) async
    func pause() async
    func resume() async
    /// False when there is no usable audio route or engine.
    var isAvailable: Bool { get async }
}

/// What a `SpeechOutput` reports back. `MotiveEngine` conforms.
///
/// Three callbacks rather than two, and the reason is hard-won: an utterance
/// that reports finishing without ever having been observed to *start* means a
/// broken audio route, not a completed line. Conflating them lets a muted queue
/// look like a spoken one.
public protocol SpeechOutputSink: AnyObject, Sendable {
    func speechDidStart(id: String, at: Date) async
    func speechDidFinish(id: String, outcome: SpeechOutcome, at: Date) async
}

/// Whether spoken input can run at all, and why not when it can't.
///
/// Not a stored preference: it is runtime truth that changes between launches
/// (the user grants permission, plugs in a microphone, fixes their bundle), and
/// a persisted copy would go stale in the dangerous direction.
public enum SpeechInputAvailability: Equatable, Sendable {
    case available
    /// The user said no. Recoverable in System Settings.
    case denied(reason: String)
    /// Structurally impossible in this build — no bundle, missing usage
    /// descriptions, no on-device model for the locale.
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }

    public var reason: String? {
        switch self {
        case .available: return nil
        case .denied(let reason), .unavailable(let reason): return reason
        }
    }
}

/// Somewhere speech can be transcribed. Implemented in `MotiveVoice`.
public protocol SpeechInput: Sendable {
    /// Begin listening for an answer to `questionID` (nil is reserved for
    /// unsolicited speech, which nothing consumes yet).
    func startListening(answering questionID: String?) async
    func stopListening() async
    var availability: SpeechInputAvailability { get async }
}

/// What a `SpeechInput` reports back.
public protocol SpeechInputSink: AnyObject, Sendable {
    func transcriptDidFinalize(_ text: String, answering questionID: String?, at: Date) async
}
