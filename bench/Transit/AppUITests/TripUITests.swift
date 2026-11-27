import XCTest

final class TripUITests: XCTestCase {
    func testBuyingShowsThePayment() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["buy"].tap()
        XCTAssertTrue(app.staticTexts["message"].label.hasPrefix("Paid"))
    }
}
