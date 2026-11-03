import XCTest

@testable import Library

/// A main-actor XCTest class with an async case: XCTest needs the main thread's run loop free to run it.
@MainActor
final class MainActorXCTests: XCTestCase {
    func testSynchronousCase() {
        XCTAssertEqual(Library.value(true), Library.value(true))
    }

    func testAsynchronousCase() async throws {
        await Task.yield()
        XCTAssertNotEqual(Library.value(true), Library.value(false))
    }
}
