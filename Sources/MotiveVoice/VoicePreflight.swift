import Foundation

/// Why a voice capability cannot be used, with the fix attached.
public struct VoiceUnavailable: Error, Equatable, Sendable, CustomStringConvertible {
    public let issues: [VoiceIssue]
    /// Set when the build is fine but the user (or the machine) said no.
    public let denial: String?

    public var description: String {
        if let denial { return denial }
        return issues.map(\.description).joined(separator: "; ")
    }

    /// Everything an embedder needs to paste, in order.
    public var fixes: [String] { issues.map(\.fix) }
}

/// Inspects the running build against a `VoiceRequirements`.
///
/// Every check here is TCC-free, which is the whole point: macOS does not
/// return an error to a process that requests the microphone without the right
/// usage descriptions, it kills it. So we must be certain *before* asking.
public enum VoicePreflight {
    /// Escape hatch for CI and for anyone who wants speech off wholesale.
    public static let disableEnvironmentKey = "MOTIVE_VOICE_DISABLED"

    public static var isDisabledByEnvironment: Bool {
        let value = ProcessInfo.processInfo.environment[disableEnvironmentKey]
        return value == "1" || value?.lowercased() == "true"
    }

    /// An unbundled executable — `swift run`, `swift test`, a CLI — has no
    /// Info.plist at all. `bundleIdentifier` is the authoritative signal.
    public static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Audit the running process. Empty means the build is capable; whether the
    /// *user* has granted permission is a separate, later question.
    public static func audit(_ requirements: VoiceRequirements) -> [VoiceIssue] {
        requirements.audit(
            infoDictionary: Bundle.main.infoDictionary,
            isBundled: isBundled,
            isSandboxed: isSandboxed
        )
    }

    /// Human-readable lines for a settings pane: what is wrong and what to do.
    public static func diagnostics(_ requirements: VoiceRequirements) -> [Diagnostic] {
        if isDisabledByEnvironment {
            return [Diagnostic(
                summary: "Speech is disabled by \(disableEnvironmentKey).",
                fix: "Unset \(disableEnvironmentKey) and relaunch."
            )]
        }
        return audit(requirements).map { Diagnostic(summary: $0.description, fix: $0.fix) }
    }

    public struct Diagnostic: Equatable, Sendable {
        public let summary: String
        public let fix: String
    }
}
