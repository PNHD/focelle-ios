import CoreGraphics

enum GuidanceDirection: String, Equatable, Sendable {
    case none, left, right, up, down, closer, farther, level, brighten, darken
}

struct Guidance: Equatable, Sendable {
    var subjectRect: CGRect?
    var target: CGPoint
    var direction: GuidanceDirection
    var instructionKey: String
    var aligned: Bool
}
