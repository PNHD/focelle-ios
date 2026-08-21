import CoreGraphics

enum GuidanceDirection: String, Equatable, Sendable {
    case none, left, right, up, down, closer, farther, level, brighten, darken

    var usesAimRing: Bool {
        switch self {
        case .none, .left, .right, .up, .down: true
        case .closer, .farther, .level, .brighten, .darken: false
        }
    }

    var usesTargetFrame: Bool { self == .closer || self == .farther }
}

enum MoveDirection: Equatable, Sendable { case left, right, up, down }
enum ScaleDirection: Equatable, Sendable { case closer, farther }
enum ExposureDirection: Equatable, Sendable { case brighten, darken }

enum GuidanceStep: Equatable, Sendable {
    case move(MoveDirection)
    case scale(ScaleDirection)
    case horizon
    case pose
    case gaze
    case spacing
    case exposure(ExposureDirection)
    case color
    case hold

    var direction: GuidanceDirection {
        switch self {
        case .move(.left): .left
        case .move(.right): .right
        case .move(.up): .up
        case .move(.down): .down
        case .scale(.closer): .closer
        case .scale(.farther): .farther
        case .horizon: .level
        case .exposure(.brighten): .brighten
        case .exposure(.darken): .darken
        case .pose, .gaze, .spacing, .color, .hold: .none
        }
    }
}

enum GuidanceSessionState: Equatable, Sendable {
    case ready
    case selectingSubject
    case analyzing
    case guiding(GuidanceStep)
    case locked
    case capturing
    case failedRecoverable
}

enum GuidanceSubjectKind: Equatable, Sendable {
    case onePerson
    case couple
    case smallGroup
    case scene
    case unavailable
}

struct GuidancePath: Equatable, Sendable {
    let start: CGPoint
    let end: CGPoint
}

struct GuidancePersonPresentation: Equatable, Sendable {
    let id: SubjectTrackID
    let frame: CGRect
    let faceFrame: CGRect?
    let isSelected: Bool
}

// The future cloud layer supplies this immutable value; the reducer still owns
// priority, hysteresis, and the single presented correction.
struct SemanticGuidanceTarget: Equatable, Sendable {
    let targetFrame: CGRect?
    let instruction: String?

    init(targetFrame: CGRect? = nil, instruction: String? = nil) {
        self.targetFrame = targetFrame
        self.instruction = instruction
    }
}

struct GuidancePresentation: Equatable, Sendable {
    let sessionState: GuidanceSessionState
    let intent: CaptureIntent
    let generation: Int
    let subjectKind: GuidanceSubjectKind
    let subjectID: SubjectTrackID?
    let subjectRect: CGRect?
    let people: [GuidancePersonPresentation]
    let target: CGPoint
    let targetRect: CGRect?
    let movementPath: GuidancePath?
    let horizonAngle: Double?
    let step: GuidanceStep?
    let instructionKey: String
    let instruction: String?

    init(
        sessionState: GuidanceSessionState,
        intent: CaptureIntent,
        generation: Int,
        subjectKind: GuidanceSubjectKind,
        subjectID: SubjectTrackID?,
        subjectRect: CGRect?,
        people: [GuidancePersonPresentation],
        target: CGPoint,
        targetRect: CGRect?,
        movementPath: GuidancePath?,
        horizonAngle: Double?,
        step: GuidanceStep?,
        instructionKey: String,
        instruction: String?
    ) {
        self.sessionState = sessionState
        self.intent = intent
        self.generation = generation
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.subjectRect = subjectRect
        self.people = people
        self.target = target
        self.targetRect = targetRect
        self.movementPath = movementPath
        self.horizonAngle = horizonAngle
        self.step = step
        self.instructionKey = instructionKey
        self.instruction = instruction
    }

    // Compatibility initializer for older call sites while migration lands.
    init(
        subjectRect: CGRect? = nil,
        target: CGPoint,
        targetRect: CGRect? = nil,
        direction: GuidanceDirection,
        instructionKey: String,
        instruction: String? = nil,
        aligned: Bool
    ) {
        let step: GuidanceStep? = switch direction {
        case .left: .move(.left)
        case .right: .move(.right)
        case .up: .move(.up)
        case .down: .move(.down)
        case .closer: .scale(.closer)
        case .farther: .scale(.farther)
        case .level: .horizon
        case .brighten: .exposure(.brighten)
        case .darken: .exposure(.darken)
        case .none: aligned ? .hold : nil
        }
        if aligned {
            sessionState = .locked
        } else if let step {
            sessionState = .guiding(step)
        } else {
            sessionState = .selectingSubject
        }
        intent = .auto
        generation = 0
        subjectKind = subjectRect == nil ? .unavailable : .scene
        subjectID = nil
        self.subjectRect = subjectRect
        people = []
        self.target = target
        self.targetRect = targetRect
        movementPath = nil
        horizonAngle = nil
        self.step = step
        self.instructionKey = instructionKey
        self.instruction = instruction
    }

    var direction: GuidanceDirection { step?.direction ?? .none }
    var aligned: Bool { sessionState == .locked || step == .hold }
    var isLocked: Bool { sessionState == .locked }
}

// Retains the existing call-site spelling while making the published value a
// typed Blueprint presentation rather than a direction-only command.
typealias Guidance = GuidancePresentation
