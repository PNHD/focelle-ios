import CoreGraphics

struct MeasurementStabilizer {
    private(set) var value: SceneMeasurement?

    mutating func update(_ next: SceneMeasurement) -> SceneMeasurement {
        guard let previous = value else {
            value = next
            return next
        }

        var result = next
        result.subjectRect = smooth(previous.subjectRect, next.subjectRect)
        result.salientRect = smooth(previous.salientRect, next.salientRect)
        result.horizonAngle = smooth(previous.horizonAngle, next.horizonAngle)
        result.exposure = previous.exposure * 0.65 + next.exposure * 0.35
        value = result
        return result
    }

    private func smooth(_ old: CGRect?, _ new: CGRect?) -> CGRect? {
        guard let old, let new else { return new }
        return CGRect(
            x: old.origin.x * 0.65 + new.origin.x * 0.35,
            y: old.origin.y * 0.65 + new.origin.y * 0.35,
            width: old.width * 0.65 + new.width * 0.35,
            height: old.height * 0.65 + new.height * 0.35
        )
    }

    private func smooth(_ old: Double?, _ new: Double?) -> Double? {
        guard let old, let new else { return new }
        return old * 0.65 + new * 0.35
    }
}
