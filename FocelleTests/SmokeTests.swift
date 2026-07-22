import XCTest
@testable import Focelle

final class SmokeTests: XCTestCase {
    func testCameraPlaceholderCanBeCreated() {
        XCTAssertNotNil(CameraPlaceholderView())
    }
}
