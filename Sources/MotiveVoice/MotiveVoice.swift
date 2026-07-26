import Foundation
import MotiveCore

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
        return .available
    }

    /// Diagnostics for a settings pane: what is wrong with this build, and the
    /// exact snippet that fixes it.
    public static func inputDiagnostics() -> [VoicePreflight.Diagnostic] {
        VoicePreflight.diagnostics(.speechInput)
    }
}
