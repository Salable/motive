import XCTest

/// Invariants that are true of the *source*, not of any runtime value. They are
/// cheap, and each one guards a promise that is otherwise easy to break by
/// accident in a hurry.
final class SourceInvariantTests: XCTestCase {
    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func swiftFiles(in target: String) throws -> [(name: String, text: String)] {
        let root = sourcesRoot.appendingPathComponent(target)
        let urls = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .map { root.appendingPathComponent($0) }
        return try urls.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// The layering rule: decision logic never learns that an audio engine —
    /// or a window — exists.
    func testCoreAndSpriteNeverImportAudioOrUI() throws {
        let forbidden = ["import AVFoundation", "import Speech", "import AppKit", "import SwiftUI"]
        for target in ["MotiveCore", "MotiveSprite"] {
            for file in try swiftFiles(in: target) {
                for line in forbidden {
                    XCTAssertFalse(
                        file.text.contains(line),
                        "\(target)/\(file.name) must not \(line)"
                    )
                }
            }
        }
    }

    /// Personal Voice authorization is TCC-protected. Touching it anywhere
    /// would silently give speech *output* a permission requirement, and the
    /// whole "TTS needs nothing" story would quietly become false.
    func testNothingRequestsPersonalVoice() throws {
        for target in ["MotiveCore", "MotiveVoice", "MotiveUI"] {
            for file in try swiftFiles(in: target) {
                XCTAssertFalse(
                    file.text.contains("requestPersonalVoiceAuthorization"),
                    "\(target)/\(file.name) would make speech output permission-gated"
                )
            }
        }
    }

    /// The privacy promise is enforced by absence: there is no code path that
    /// can write an audio file or fall back to server-side recognition.
    func testNoAudioFileOrServerRecognitionPath() throws {
        for file in try swiftFiles(in: "MotiveVoice") {
            XCTAssertFalse(
                file.text.contains("SFSpeechURLRecognitionRequest"),
                "\(file.name) would transcribe from a file — no audio file is ever written"
            )
            XCTAssertFalse(
                file.text.contains("requiresOnDeviceRecognition = false"),
                "\(file.name) would send audio off the machine"
            )
        }
    }

    /// The security invariant, guarded at the source level too: no transport
    /// method may exist that submits an answer.
    func testNoTransportMethodAnswersAQuestion() throws {
        for file in try swiftFiles(in: "MotiveMCP") {
            for forbidden in ["func answerQuestion", "func submitAnswer", "func resolveQuestion"] {
                XCTAssertFalse(
                    file.text.contains(forbidden),
                    "\(file.name): answers originate only from UI input"
                )
            }
        }
    }
}
