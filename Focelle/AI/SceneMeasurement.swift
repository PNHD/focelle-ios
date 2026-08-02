import CoreGraphics
import Foundation

struct SceneMeasurement: Equatable, Sendable {
    var subjectRect: CGRect?
    var humanRects: [CGRect] = []
    var faceRects: [CGRect]
    var bodyPoseCount: Int = 0
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

    func subject(near point: CGPoint) -> CGRect? {
        let containingHumans = humanRects.filter { $0.contains(point) }
        let candidates =
            containingHumans.isEmpty
            ? humanRects + faceRects + [subjectRect, salientRect].compactMap { $0 }
            : containingHumans
        return candidates.min {
            hypot(point.x - $0.midX, point.y - $0.midY)
                < hypot(point.x - $1.midX, point.y - $1.midY)
        }
    }
}
