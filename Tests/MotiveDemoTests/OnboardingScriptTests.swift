import XCTest
import MotiveSprite
@testable import MotiveDemo

/// The tour plays through `MotiveEngine.playScript`, which flushes the queue
/// before validation can fail — a script that drifts out of Winston's
/// vocabulary means a silently empty first launch. These tests pin the script
/// to the real bundled sprite so that drift breaks CI instead.
final class OnboardingScriptTests: XCTestCase {
    /// Sprites/winston resolved from this file, so the tests run from any
    /// checkout location without a bundle.
    private func winstonDefinition() throws -> SpriteDefinition {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OnboardingScriptTests.swift
            .deletingLastPathComponent()  // MotiveDemoTests
            .deletingLastPathComponent()  // Tests
        return try SpriteRunnerRegistry.standard.load(root.appendingPathComponent("Sprites/winston"))
    }

    func testTourValidatesAgainstBundledWinston() throws {
        let definition = try winstonDefinition()
        let script = onboardingScript(name: "Winston")
        let failure = script.validate(against: definition.behaviorDefinition)
        XCTAssertNil(failure, "onboarding must stay inside Winston's vocabulary: \(String(describing: failure))")
    }

    func testTourFitsTheQueue() {
        let script = onboardingScript(name: "Winston")
        XCTAssertFalse(script.steps.isEmpty)
        XCTAssertLessThanOrEqual(
            script.steps.count, ScriptRun.maxSteps,
            "the tour must fit in one queue-replacement"
        )
    }

    func testTourMentionsTheQueueWindow() {
        // The tour is the demo's discovery surface; keep the queue window in it.
        let says = onboardingScript(name: "Winston").steps.compactMap { step -> String? in
            if case .say(let text, _) = step { return text }
            return nil
        }
        XCTAssertTrue(
            says.contains { $0.contains("Queue…") },
            "the tour should point at the paw menu's Queue… window"
        )
    }
}
