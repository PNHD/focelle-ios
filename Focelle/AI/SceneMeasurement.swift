import CoreGraphics
import Foundation

struct SceneMeasurement: Equatable, Sendable {
    var subjectRect: CGRect?
    var faceRects: [CGRect]
    var salientRect: CGRect?
    var horizonAngle: Double?
    var exposure: Double
    var faceReady: Bool = true
    var timestamp: TimeInterval

    var primaryRect: CGRect? {
        subjectRect
            ?? faceRects.max { $0.width * $0.height < $1.width * $1.height }
            ?? salientRect
    }
}
