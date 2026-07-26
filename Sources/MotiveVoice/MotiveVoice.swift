import Foundation
import AVFoundation
import MotiveCore
import Speech

/// The entry point for voice.
///
/// Speech *output* is freely constructible — it needs no permission, no bundle,
/// and no Info.plist keys. Speech *input* is not: the only way to obtain one is
/// through a factory that returns a `Result`, so an embedder who has never read
/// our docs meets the requirement as a value they must destructure rather than
/// as a crash report from a user. There is no `force:` override, because there
/// is no legitimate use for one — the predicate is the OS's own precondition.
public enum MotiveVoice {
    // MARK: output

    /// Build spoken output. Returns nil only when speech is disabled wholesale
    /// by the environment (CI).
    public static func makeSpeechOutput() -> AVSpeechOutput? {
        guard !VoicePreflight.isDisabledByEnvironment else { return nil }
        return AVSpeechOutput()
    }

    /// Requirements for speaking aloud — deliberately empty. Exposed so an
    /// embedder can assert on it rather than assume it.
    public static var outputRequirements: VoiceRequirements { .speechOutput }

    // MARK: input

    public static var inputRequirements: VoiceRequirements { .speechInput }

    /// Whether this build *could* listen, before any permission is requested.
    /// Runtime truth, never persisted: it changes when the user grants
    /// permission or fixes their bundle, and a stored copy would be stale in
    /// the dangerous direction.
    public static func inputAvailability() -> SpeechInputAvailability {
        if VoicePreflight.isDisabledByEnvironment {
            return .unavailable(reason: "speech is disabled by \(VoicePreflight.disableEnvironmentKey)")
        }
        let issues = VoicePreflight.audit(.speechInput)
        guard issues.isEmpty else {
            return .unavailable(reason: issues.map(\.description).joined(separator: "; "))
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) else {
            return .unavailable(reason: "no speech recognizer for \(Locale.current.identifier)")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .unavailable(
                reason: "\(Locale.current.identifier) has no on-device speech model — refusing rather than sending audio off this Mac"
            )
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            return .denied(reason: "speech recognition is turned off for this app in System Settings")
        default:
            break
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            return .denied(reason: "microphone access is turned off for this app in System Settings")
        }
        return .available
    }

    /// Build speech input, or explain why this build cannot.
    ///
    /// The only way to obtain one. There is no `force:` override: the predicate
    /// is the operating system's own precondition, and skipping it does not get
    /// you a degraded feature, it gets your app killed.
    public static func makeSpeechInput(
        locale: Locale = Locale.current
    ) -> Result<SFSpeechInput, VoiceUnavailable> {
        if isDisabledByEnvironment() {
            return .failure(VoiceUnavailable(
                issues: [],
                denial: "speech is disabled by \(VoicePreflight.disableEnvironmentKey)"
            ))
        }
        let issues = VoicePreflight.audit(.speechInput)
        guard issues.isEmpty else {
            return .failure(VoiceUnavailable(issues: issues, denial: nil))
        }
        // Constructing a recognizer and reading its capabilities is TCC-free,
        // so this can be checked before anything prompts the user.
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .failure(VoiceUnavailable(
                issues: [], denial: "no speech recognizer for \(locale.identifier)"
            ))
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .failure(VoiceUnavailable(
                issues: [],
                denial: "\(locale.identifier) has no on-device speech model — refusing rather than sending audio off this Mac"
            ))
        }
        return .success(SFSpeechInput(recognizer: recognizer))
    }

    static func isDisabledByEnvironment() -> Bool { VoicePreflight.isDisabledByEnvironment }

    /// Diagnostics for a settings pane: what is wrong with this build, and the
    /// exact snippet that fixes it.
    public static func inputDiagnostics() -> [VoicePreflight.Diagnostic] {
        VoicePreflight.diagnostics(.speechInput)
    }
}
