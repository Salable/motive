import XCTest
@testable import MotiveVoice

/// The audit is pure and takes a dictionary rather than only a URL precisely so
/// these can run with no filesystem and no audio device.
final class VoiceRequirementsTests: XCTestCase {
    private let good: [String: Any] = [
        "NSMicrophoneUsageDescription": "Winston listens when you answer out loud.",
        "NSSpeechRecognitionUsageDescription": "Winston transcribes your reply on-device.",
    ]

    func testSpeakingAloudRequiresNothing() {
        let issues = VoiceRequirements.speechOutput.audit(infoDictionary: [:], isBundled: false)
        XCTAssertTrue(issues.isEmpty, "TTS must stay permission-free and bundle-free")
        XCTAssertTrue(VoiceRequirements.speechOutput.plistKeys.isEmpty)
    }

    func testCleanBundlePasses() {
        let issues = VoiceRequirements.speechInput.audit(infoDictionary: good, isBundled: true)
        XCTAssertEqual(issues, [])
    }

    /// The failure that kills apps: no bundle at all, so no plist can carry the
    /// usage descriptions macOS demands before it will even deny politely.
    func testUnbundledIsCaught() {
        let issues = VoiceRequirements.speechInput.audit(infoDictionary: good, isBundled: false)
        XCTAssertTrue(issues.contains(.notBundled))
    }

    func testMissingKeyIsCaught() {
        let partial = ["NSMicrophoneUsageDescription": "listens"]
        let issues = VoiceRequirements.speechInput.audit(infoDictionary: partial, isBundled: true)
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue("\(issues[0])".contains("NSSpeechRecognitionUsageDescription"))
    }

    /// Recent macOS treats an empty purpose string as absent, so a lenient
    /// check here would re-open the kill path this exists to close.
    func testEmptyOrWhitespaceKeyCountsAsMissing() {
        for value in ["", "   ", "\n"] {
            let info: [String: Any] = [
                "NSMicrophoneUsageDescription": value,
                "NSSpeechRecognitionUsageDescription": "fine",
            ]
            let issues = VoiceRequirements.speechInput.audit(infoDictionary: info, isBundled: true)
            XCTAssertEqual(issues.count, 1, "empty purpose string must not pass")
        }
    }

    func testWrongTypeCountsAsMissing() {
        let info: [String: Any] = [
            "NSMicrophoneUsageDescription": 42,
            "NSSpeechRecognitionUsageDescription": "fine",
        ]
        let issues = VoiceRequirements.speechInput.audit(infoDictionary: info, isBundled: true)
        XCTAssertEqual(issues.count, 1)
    }

    func testNilInfoDictionaryFailsEveryKey() {
        let issues = VoiceRequirements.speechInput.audit(infoDictionary: nil, isBundled: true)
        XCTAssertEqual(issues.count, VoiceRequirements.speechInput.plistKeys.count)
    }

    /// The silent-failure case: keys present, sandboxed, no audio entitlement.
    func testSandboxedWithoutEntitlementIsCaught() {
        let issues = VoiceRequirements.speechInput.audit(
            infoDictionary: good, isBundled: true, isSandboxed: true, entitlements: [:]
        )
        XCTAssertEqual(issues, [.missingEntitlement("com.apple.security.device.audio-input")])
    }

    func testSandboxedWithEntitlementPasses() {
        let issues = VoiceRequirements.speechInput.audit(
            infoDictionary: good, isBundled: true, isSandboxed: true,
            entitlements: ["com.apple.security.device.audio-input": true]
        )
        XCTAssertEqual(issues, [])
    }

    /// The docs quote this; if it drifted from the manifest the requirement we
    /// document and the one we enforce would diverge.
    func testPlistFragmentNamesEveryRequiredKey() {
        let xml = VoiceRequirements.speechInput.plistFragmentXML
        for key in VoiceRequirements.speechInput.plistKeys {
            XCTAssertTrue(xml.contains(key.key), "fragment should mention \(key.key)")
        }
        XCTAssertTrue(xml.contains("TODO:"), "the author must write their own purpose strings")
    }

    func testEveryIssueCarriesAnActionableFix() {
        let issues = VoiceRequirements.speechInput.audit(infoDictionary: nil, isBundled: false)
        XCTAssertFalse(issues.isEmpty)
        for issue in issues {
            XCTAssertFalse(issue.fix.isEmpty, "an issue with no fix is just a complaint")
        }
    }

    // MARK: this repo's own bundle

    /// The committed demo plist must satisfy the requirement, so the shipped
    /// app can never regress into the kill path.
    func testCommittedInfoPlistSatisfiesSpeechInput() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MotiveVoiceTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let plistURL = repoRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
        let issues = VoiceRequirements.speechInput.audit(infoDictionary: info, isBundled: true)
        XCTAssertEqual(issues, [], "Resources/Info.plist is missing voice keys")
    }

    // MARK: preflight

    func testInputAvailabilityExplainsItselfWhenUnavailable() {
        // Under `swift test` Bundle.main is xctest's, which carries no usage
        // descriptions — so this exercises the real refusal path.
        let availability = MotiveVoice.inputAvailability()
        if case .available = availability {
            // A machine where the test host happens to qualify: fine.
            return
        }
        XCTAssertNotNil(availability.reason, "a refusal must say why")
        XCTAssertFalse(MotiveVoice.inputDiagnostics().isEmpty)
        XCTAssertFalse(MotiveVoice.inputDiagnostics()[0].fix.isEmpty)
    }

    func testDisablingByEnvironmentIsHonoured() {
        guard VoicePreflight.isDisabledByEnvironment else { return }
        guard case .unavailable(let reason) = MotiveVoice.inputAvailability() else {
            return XCTFail("MOTIVE_VOICE_DISABLED must win")
        }
        XCTAssertTrue(reason.contains(VoicePreflight.disableEnvironmentKey))
    }
}
