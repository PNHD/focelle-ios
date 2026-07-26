import CoreGraphics

enum GuidanceDirection: String, Equatable, Sendable {
    case none, left, right, up, down, closer, farther, level, brighten, darken

    var usesAimRing: Bool {
        switch self {
        case .none, .left, .right, .up, .down: true
        case .closer, .farther, .level, .brighten, .darken: false
        }
    }

    var usesTargetFrame: Bool {
        self == .closer || self == .farther
    }
}

struct Guidance: Equatable, Sendable {
    var subjectRect: CGRect?
    var target: CGPoint
    var targetRect: CGRect? = nil
    var direction: GuidanceDirection
    var instructionKey: String
    var instruction: String? = nil
    var aligned: Bool
}
