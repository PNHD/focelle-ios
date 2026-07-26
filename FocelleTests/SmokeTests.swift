import XCTest
@testable import Focelle

final class SmokeTests: XCTestCase {
    func testCameraViewCanBeCreated() {
        XCTAssertNotNil(CameraView())
    }

    func testRestrictedCameraPermissionIsDenied() {
        XCTAssertEqual(CameraPermission(.restricted), .denied)
        XCTAssertEqual(CameraPermission(.authorized), .allowed)
    }

    func testPhotoResolutionChoosesClosestTo24Megapixels() {
        let options = [
            PhotoDimensions(width: 4_032, height: 3_024),
            PhotoDimensions(width: 5_712, height: 4_284),
            PhotoDimensions(width: 8_064, height: 6_048),
        ]

        XCTAssertEqual(PhotoDimensions.standard(in: options), options[1])
    }

    func testCameraRotationMatchesInterfaceOrientation() {
        XCTAssertEqual(CameraRotation.angle(for: .portrait), 90)
        XCTAssertEqual(CameraRotation.angle(for: .landscapeLeft), 0)
        XCTAssertEqual(CameraRotation.angle(for: .landscapeRight), 180)
    }
}
