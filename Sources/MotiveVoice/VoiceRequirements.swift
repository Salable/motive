import Foundation

/// What a build must provide before a voice capability can run.
///
/// One source of truth with three consumers: the runtime gate evaluates it, the
/// docs quote its generated plist fragment, and an embedder can assert on it in
/// their own tests. A separate hand-written checklist would drift from the
/// enforced predicate the first time either changed.
public struct VoiceRequirements: Sendable {
    /// Info.plist keys that must be present and non-empty.
    public let plistKeys: [PlistKey]
    /// Entitlements required when the app is sandboxed.
    public let sandboxEntitlements: [String]
    /// True when the capability cannot run outside an app bundle.
    public let requiresBundle: Bool

    public struct PlistKey: Sendable, Equatable {
        public let key: String
        /// What the string is for, so an author writes their own rather than
        /// pasting boilerplate at their users.
        public let purpose: String
    }

    /// Speaking aloud needs nothing: no permission, no bundle, no plist keys.
    ///
    /// This stays true only because we never touch Personal Voice, whose
    /// authorization request *is* TCC-protected. Enforced by a source test.
    public static let speechOutput = VoiceRequirements(
        plistKeys: [], sandboxEntitlements: [], requiresBundle: false
    )

    /// Listening needs a bundle, two usage descriptions, and — when sandboxed —
    /// the audio-input entitlement. Without the plist keys macOS does not
    /// return an error, it kills the process.
    public static let speechInput = VoiceRequirements(
        plistKeys: [
            PlistKey(
                key: "NSMicrophoneUsageDescription",
                purpose: "Why your app listens. Shown in the system permission prompt."
            ),
            PlistKey(
                key: "NSSpeechRecognitionUsageDescription",
                purpose: "Why your app transcribes speech. Shown in the system permission prompt."
            ),
        ],
        sandboxEntitlements: ["com.apple.security.device.audio-input"],
        requiresBundle: true
    )

    // MARK: audit

    /// Check an info dictionary and entitlements. Pure, so it is testable
    /// without a filesystem and reusable against any bundle.
    public func audit(
        infoDictionary: [String: Any]?,
        isBundled: Bool,
        isSandboxed: Bool = false,
        entitlements: [String: Any] = [:]
    ) -> [VoiceIssue] {
        var issues: [VoiceIssue] = []
        if requiresBundle, !isBundled {
            issues.append(.notBundled)
        }
        for key in plistKeys {
            let value = infoDictionary?[key.key] as? String
            // An empty purpose string reads as missing to recent macOS, so a
            // lenient check here would re-open the kill path it exists to close.
            if value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                issues.append(.missingPlistKey(key))
            }
        }
        if isSandboxed {
            for entitlement in sandboxEntitlements
            where (entitlements[entitlement] as? Bool) != true {
                issues.append(.missingEntitlement(entitlement))
            }
        }
        return issues
    }

    /// Audit a built `.app` — what a packaging script or CI step calls.
    public func audit(appBundleAt url: URL) -> [VoiceIssue] {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plistURL.path),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else {
            return [.unreadableBundle(plistURL.path)]
        }
        return audit(infoDictionary: info, isBundled: true)
    }

    /// Paste-into-Info.plist XML for the keys this capability needs. Generated
    /// from the same manifest the gate evaluates, so it cannot drift from it.
    public var plistFragmentXML: String {
        guard !plistKeys.isEmpty else { return "<!-- no Info.plist keys required -->" }
        return plistKeys.map { key in
            """
            <key>\(key.key)</key>
            <string>TODO: \(key.purpose)</string>
            """
        }.joined(separator: "\n")
    }

    /// Equivalent Xcode build settings, for embedders who generate their plist.
    public var xcodeBuildSettings: String {
        plistKeys.map { "INFOPLIST_KEY_\($0.key) = TODO: \($0.purpose)" }
            .joined(separator: "\n")
    }
}

/// Something missing from a build that a voice capability needs.
public enum VoiceIssue: Equatable, Sendable, CustomStringConvertible {
    case notBundled
    case missingPlistKey(VoiceRequirements.PlistKey)
    case missingEntitlement(String)
    case unreadableBundle(String)

    public var description: String {
        switch self {
        case .notBundled:
            return "not running inside an app bundle — an unbundled executable has no Info.plist to carry usage descriptions"
        case .missingPlistKey(let key):
            return "Info.plist is missing a non-empty \(key.key)"
        case .missingEntitlement(let name):
            return "sandboxed build is missing the \(name) entitlement"
        case .unreadableBundle(let path):
            return "could not read \(path)"
        }
    }

    /// What to actually do about it.
    public var fix: String {
        switch self {
        case .notBundled:
            return "Build a .app bundle (see docs/EMBEDDING.md → Ship an app bundle). Speech output needs no bundle; speech input does."
        case .missingPlistKey(let key):
            return "<key>\(key.key)</key>\n<string>TODO: \(key.purpose)</string>"
        case .missingEntitlement(let name):
            return "<key>\(name)</key>\n<true/>"
        case .unreadableBundle:
            return "Check the path points at a built .app."
        }
    }
}
