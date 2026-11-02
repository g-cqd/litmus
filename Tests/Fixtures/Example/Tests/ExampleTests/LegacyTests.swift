import XCTest
import Example

final class LegacyTests: XCTestCase {
    func testPermission() { XCTAssertTrue(permitted(true)) }
}
