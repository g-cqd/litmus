import XCTest

@testable import ExampleApp

final class LegacyTests: XCTestCase {
    func testPermission() { XCTAssertTrue(permitted(true)) }
}
