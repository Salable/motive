import XCTest
@testable import MotiveSprite

final class FixtureSmokeTests: XCTestCase {
    func testWinstonFixtureIsPresent() {
        let manifest = Fixtures.winston.appendingPathComponent("motive.json")
        let sheet = Fixtures.winston.appendingPathComponent("spritesheet.webp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sheet.path))
    }
}
