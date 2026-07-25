import XCTest
@testable import MotiveCore

final class MotiveVersionTests: XCTestCase {
    func testVersionIsSemver() {
        let parts = MotiveVersion.current.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }

    /// `MotiveVersion.current` is the single source of truth for a release.
    /// The packaging script stamps the app bundle's plist from it at build
    /// time; this keeps the committed plist honest too, so a checkout never
    /// carries two versions.
    func testBundlePlistMatchesVersionConstant() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MotiveVersionTests.swift
            .deletingLastPathComponent()  // MotiveCoreTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(
            plist["CFBundleShortVersionString"] as? String,
            MotiveVersion.current,
            "Resources/Info.plist drifted from MotiveVersion.current — bump both (RELEASING.md step 2)"
        )
    }
}
