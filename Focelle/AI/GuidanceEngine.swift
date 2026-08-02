import CoreGraphics
import Foundation

// One instruction has to survive long enough for a person to carry it out.
// Every threshold below therefore comes in pairs: a wider one that starts a
// goal and a narrower one that ends it. A single threshold makes the advice
// oscillate as soon as the subject sits near it.
struct GuidanceEngine {
    static let maxHold: TimeInterval = 4

    private var goal: GuidanceDirection?
    private var goalSince: TimeInterval = 0
    private var latchedSide: Double?

    mutating func update(_ measurement: SceneMeasurement) -> Guidance {
        guard let rect = Self.uprightRect(measurement) else {
            goal = nil
            latchedSide = nil
            return Guidance(
                target: CGPoint(x: 0.5, y: 0.5),
                direction: .none,
                instructionKey: "guidance.findSubject",
                aligned: false
            )
        }

        let side = Self.side(for: rect, latched: latchedSide)
        latchedSide = side
        let target = CGPoint(x: Self.targetX(side: side, width: rect.width), y: 0.5)

        if let held = goal,
            held != .none,
            measurement.timestamp - goalSince < Self.maxHold,
            !Self.isCleared(held, rect: rect, target: target, measurement: measurement)
        {
            return Self.guidance(held, rect: rect, target: target)
        }

        let next = Self.goal(rect: rect, target: target, measurement: measurement)
        if next != goal {
            goal = next
            goalSince = measurement.timestamp
        }
        return Self.guidance(next, rect: rect, target: target)
    }

    static func propose(_ measurement: SceneMeasurement) -> Guidance {
        guard let rect = uprightRect(measurement) else {
            return Guidance(
                target: CGPoint(x: 0.5, y: 0.5),
                direction: .none,
                instructionKey: "guidance.findSubject",
                aligned: false
            )
        }
        let side = side(for: rect, latched: nil)
        let target = CGPoint(x: targetX(side: side, width: rect.width), y: 0.5)
        return guidance(goal(rect: rect, target: target, measurement: measurement), rect: rect, target: target)
    }

    // Vision reports a bottom-left origin; the rest of the app works top-left.
    static func uprightRect(_ measurement: SceneMeasurement) -> CGRect? {
        guard let visionRect = measurement.primaryRect else { return nil }
        return CGRect(
            x: visionRect.minX,
            y: 1 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        )
    }

    // Switching thirds needs the subject well past centre. Choosing purely on
    // midX < 0.5 made the target jump the moment a subject crossed the middle.
    static func side(for rect: CGRect, latched: Double?) -> Double {
        let left = 1.0 / 3
        let right = 2.0 / 3
        guard let latched else { return rect.midX < 0.5 ? left : right }
        if latched == left, rect.midX > 0.62 { return right }
        if latched == right, rect.midX < 0.38 { return left }
        return latched
    }

    // A subject that fills the frame belongs centred, but easing across that
    // range matters more than the endpoints: the old rule teleported the target
    // the instant width crossed 0.42, which read as "move closer" turning into
    // "move left" while the user was still walking in.
    static func targetX(side: Double, width: CGFloat) -> Double {
        let centred = Double(min(max((width - 0.30) / 0.20, 0), 1))
        return side + (0.5 - side) * centred
    }

    static func goal(
        rect: CGRect,
        target: CGPoint,
        measurement: SceneMeasurement
    ) -> GuidanceDirection {
        let area = rect.width * rect.height
        let dx = rect.midX - target.x
        let dy = rect.midY - target.y

        if let horizon = measurement.horizonAngle, abs(horizon) > 0.05 { return .level }
        if area < 0.045 { return .closer }
        if area > 0.55 { return .farther }
        if dx < -0.10 { return .left }
        if dx > 0.10 { return .right }
        if dy < -0.11 { return .up }
        if dy > 0.11 { return .down }
        if measurement.exposure < 0.18 { return .brighten }
        if measurement.exposure > 0.88 { return .darken }
        return .none
    }

    static func isCleared(
        _ goal: GuidanceDirection,
        rect: CGRect,
        target: CGPoint,
        measurement: SceneMeasurement
    ) -> Bool {
        let area = rect.width * rect.height
        let dx = rect.midX - target.x
        let dy = rect.midY - target.y

        switch goal {
        case .level: return abs(measurement.horizonAngle ?? 0) < 0.025
        case .closer: return area > 0.075
        case .farther: return area < 0.45
        case .left: return dx > -0.05
        case .right: return dx < 0.05
        case .up: return dy > -0.055
        case .down: return dy < 0.055
        case .brighten: return measurement.exposure > 0.26
        case .darken: return measurement.exposure < 0.80
        case .none: return true
        }
    }

    private static func guidance(
        _ direction: GuidanceDirection,
        rect: CGRect,
        target: CGPoint
    ) -> Guidance {
        Guidance(
            subjectRect: rect,
            target: target,
            direction: direction,
            instructionKey: key(for: direction),
            aligned: direction == .none
        )
    }

    private static func key(for direction: GuidanceDirection) -> String {
        switch direction {
        case .none: "guidance.ready"
        case .left: "guidance.left"
        case .right: "guidance.right"
        case .up: "guidance.up"
        case .down: "guidance.down"
        case .closer: "guidance.closer"
        case .farther: "guidance.farther"
        case .level: "guidance.level"
        case .brighten: "guidance.brighter"
        case .darken: "guidance.darker"
        }
    }
}
