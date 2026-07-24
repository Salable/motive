import XCTest
@testable import MotiveSprite

final class FixtureSmokeTests: XCTestCase {
    func testSalliFixtureIsPresent() {
        let manifest = Fixtures.salli.appendingPathComponent("pet.json")
        let sheet = Fixtures.salli.appendingPathComponent("spritesheet.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sheet.path))
    }
}
