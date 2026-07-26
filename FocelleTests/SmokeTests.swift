import CoreImage
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

    func testOriginalFiltersAreOwnedUniqueRecipes() {
        XCTAssertEqual(FocelleOriginals.all.count, 12)
        XCTAssertEqual(Set(FocelleOriginals.all.map(\.id)).count, 12)
    }

    func testEveryOriginalFilterRendersSyntheticImage() {
        let renderer = FilterRenderer()
        let input = CIImage(color: .init(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))

        for recipe in FocelleOriginals.all {
            XCTAssertEqual(renderer.render(input, recipe: recipe).extent, input.extent)
        }
    }
}
