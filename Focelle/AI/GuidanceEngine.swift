import CoreGraphics
import Foundation

struct GuidanceEngine {
    private var pendingDirection: GuidanceDirection?
    private var pendingCount = 0
    private var accepted: Guidance?

    mutating func update(_ measurement: SceneMeasurement) -> Guidance {
        let proposed = Self.propose(measurement)
        guard let accepted else {
            self.accepted = proposed
            return proposed
        }
        guard proposed.direction != accepted.direction else {
            pendingDirection = nil
            pendingCount = 0
            self.accepted = proposed
            return proposed
        }

        if pendingDirection == proposed.direction {
            pendingCount += 1
        } else {
            pendingDirection = proposed.direction
            pendingCount = 1
        }
        guard pendingCount >= 2 else { return accepted }

        pendingDirection = nil
        pendingCount = 0
        self.accepted = proposed
        return proposed
    }

    static func propose(_ measurement: SceneMeasurement) -> Guidance {
        guard let visionRect = measurement.primaryRect else {
            return Guidance(
                target: CGPoint(x: 0.5, y: 0.5),
                direction: .none,
                instructionKey: "guidance.findSubject",
                aligned: false
            )
        }

        let rect = CGRect(
            x: visionRect.minX,
            y: 1 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        )
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let targetX = rect.width > 0.42 ? 0.5 : (center.x < 0.5 ? 1.0 / 3 : 2.0 / 3)
        let target = CGPoint(x: targetX, y: 0.5)
        let area = rect.width * rect.height

        let direction: GuidanceDirection
        let key: String
        if let horizon = measurement.horizonAngle, abs(horizon) > 0.05 {
            direction = .level
            key = "guidance.level"
        } else if area < 0.045 {
            direction = .closer
            key = "guidance.closer"
        } else if area > 0.55 {
            direction = .farther
            key = "guidance.farther"
        } else if center.x < target.x - 0.07 {
            direction = .left
            key = "guidance.left"
        } else if center.x > target.x + 0.07 {
            direction = .right
            key = "guidance.right"
        } else if center.y < target.y - 0.08 {
            direction = .up
            key = "guidance.up"
        } else if center.y > target.y + 0.08 {
            direction = .down
            key = "guidance.down"
        } else if measurement.exposure < 0.18 {
            direction = .brighten
            key = "guidance.brighter"
        } else if measurement.exposure > 0.88 {
            direction = .darken
            key = "guidance.darker"
        } else {
            direction = .none
            key = "guidance.ready"
        }

        return Guidance(
            subjectRect: rect,
            target: target,
            direction: direction,
            instructionKey: key,
            aligned: direction == .none
        )
    }
}
