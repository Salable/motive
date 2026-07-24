import XCTest
@testable import MotiveHTTP

final class PlaceholderTests: XCTestCase {
    func testTargetLinks() {
        XCTAssertFalse(MotiveVersion.current.isEmpty)
    }
}
