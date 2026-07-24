import XCTest
@testable import MotiveCore

final class MotiveVersionTests: XCTestCase {
    func testVersionIsSemver() {
        let parts = MotiveVersion.current.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }
}
