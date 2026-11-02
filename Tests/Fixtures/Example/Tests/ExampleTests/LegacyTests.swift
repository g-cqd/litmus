import Example
import XCTest

final class LegacyTests: XCTestCase {
    func testPermission() { XCTAssertTrue(permitted(true)) }
}
