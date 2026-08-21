import CoreGraphics
import Foundation

// A deterministic, local reducer. It selects one correction from current
// Vision/device geometry and holds it until its tighter exit threshold is met.
// No cloud result is needed to keep the viewfinder useful.
struct GuidanceEngine {
    private struct Context: Equatable {
        let intent: CaptureIntent
        let generation: Int
        let subjectID: SubjectTrackID?
        let semanticTarget: SemanticGuidanceTarget?
    }

    private var context: Context?
    private(set) var state: GuidanceSessionState = .ready
    private(set) var currentPresentation: GuidancePresentation?

    mutating func update(
        _ measurement: SceneMeasurement,
        intent: CaptureIntent = .auto,
        generation: Int = 0,
        selectedSubjectID: SubjectTrackID? = nil,
        semanticTarget: SemanticGuidanceTarget? = nil
    ) -> GuidancePresentation {
        let selectedID = selectedSubjectID ?? measurement.selectedSubjectID
        let nextContext = Context(
            intent: intent,
            generation: generation,
            subjectID: selectedID,
            semanticTarget: semanticTarget
        )
        if context != nextContext {
            context = nextContext
            state = .analyzing
            currentPresentation = nil
        }

        var measured = measurement
        measured.selectedSubjectID = selectedID
        let proposal = Self.proposal(
            measurement: measured,
            intent: intent,
            generation: generation,
            semanticTarget: semanticTarget
        )

        if case .guiding(let activeStep) = state,
            !Self.isSatisfied(activeStep, measurement: measured, intent: intent, target: proposal.target),
            !Self.materiallyContradicts(activeStep, proposal.step)
        {
            let held = Self.presentation(
                for: activeStep,
                measurement: measured,
                intent: intent,
                generation: generation,
                subjectKind: proposal.subjectKind,
                target: proposal.target,
                targetRect: proposal.targetRect,
                semanticTarget: semanticTarget,
                sessionState: .guiding(activeStep)
            )
            currentPresentation = held
            return held
        }

        let presentation: GuidancePresentation
        switch proposal.step {
        case nil:
            state = .selectingSubject
            presentation = Self.selectionPresentation(
                measurement: measured,
                intent: intent,
                generation: generation
            )
        case .some(.hold):
            state = .locked
            presentation = Self.presentation(
                for: .hold,
                measurement: measured,
                intent: intent,
                generation: generation,
                subjectKind: proposal.subjectKind,
                target: proposal.target,
                targetRect: proposal.targetRect,
                semanticTarget: semanticTarget,
                sessionState: .locked
            )
        case .some(let step):
            state = .guiding(step)
            presentation = Self.presentation(
                for: step,
                measurement: measured,
                intent: intent,
                generation: generation,
                subjectKind: proposal.subjectKind,
                target: proposal.target,
                targetRect: proposal.targetRect,
                semanticTarget: semanticTarget,
                sessionState: .guiding(step)
            )
        }
        currentPresentation = presentation
        return presentation
    }

    mutating func reset() {
        context = nil
        state = .ready
        currentPresentation = nil
    }

    mutating func beginCapture() {
        state = .capturing
        currentPresentation = nil
    }

    mutating func completeCapture(recoverableFailure: Bool = false) {
        context = nil
        state = recoverableFailure ? .failedRecoverable : .ready
        currentPresentation = nil
    }

    // Compatibility helper for existing call sites/tests. It is still backed
    // by the reducer rather than an independent direction chooser.
    static func propose(_ measurement: SceneMeasurement) -> GuidancePresentation {
        var engine = GuidanceEngine()
        return engine.update(measurement)
    }

    // Vision uses bottom-left coordinates; SwiftUI overlay coordinates are
    // top-left. The candidate crop-space resolution remains for the later UX
    // slice, so this kernel only preserves the existing normalized convention.
    static func uprightRect(_ measurement: SceneMeasurement) -> CGRect? {
        measurement.primaryRect.map(upright)
    }

    static func side(for rect: CGRect, latched: Double?) -> Double {
        let left = 1.0 / 3
        let right = 2.0 / 3
        guard let latched else { return rect.midX < 0.5 ? left : right }
        if latched == left, rect.midX > 0.62 { return right }
        if latched == right, rect.midX < 0.38 { return left }
        return latched
    }

    static func targetX(side: Double, width: CGFloat) -> Double {
        let centred = Double(min(max((width - 0.30) / 0.20, 0), 1))
        return side + (0.5 - side) * centred
    }

    private static func proposal(
        measurement: SceneMeasurement,
        intent: CaptureIntent,
        generation _: Int,
        semanticTarget: SemanticGuidanceTarget?
    ) -> (step: GuidanceStep?, subjectKind: GuidanceSubjectKind, target: CGPoint, targetRect: CGRect?) {
        let effectiveIntent: CaptureIntent = intent == .auto
            ? (measurement.people.isEmpty ? .scene : .people)
            : intent
        let kind = subjectKind(for: measurement, intent: effectiveIntent)
        guard kind != .unavailable else {
            return (nil, .unavailable, CGPoint(x: 0.5, y: 0.5), semanticTarget?.targetFrame)
        }

        let visionRect: CGRect?
        switch kind {
        case .couple, .smallGroup: visionRect = measurement.group?.envelope
        case .onePerson: visionRect = measurement.selectedPerson?.humanRect ?? measurement.primaryRect
        case .scene:
            visionRect = measurement.scene.primarySubjectRect ?? measurement.salientRect ?? measurement.primaryRect
        case .unavailable: visionRect = nil
        }
        let subject = visionRect.map(upright)
        let side = subject.map { side(for: $0, latched: nil) } ?? 0.5
        let localTarget = CGPoint(
            x: kind == .onePerson && subject != nil ? targetX(side: side, width: subject!.width) : 0.5,
            y: 0.5
        )
        let targetRect = semanticTarget?.targetFrame
        let target = targetRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? localTarget

        if let horizon = measurement.horizonAngle, abs(horizon) > 0.05 {
            return (.horizon, kind, target, targetRect)
        }
        if let group = measurement.group, kind == .couple || kind == .smallGroup {
            if group.maximumOverlap > 0.10 || group.memberSpacing.contains(where: { $0 < 0.015 }) {
                return (.spacing, kind, target, targetRect)
            }
        }
        guard let subject else {
            if let exposure = exposureDirection(for: measurement.exposure) {
                return (.exposure(exposure), kind, target, targetRect)
            }
            return (.hold, kind, target, targetRect)
        }
        let area = subject.width * subject.height
        if area < 0.045 { return (.scale(.closer), kind, target, targetRect) }
        if area > 0.55 { return (.scale(.farther), kind, target, targetRect) }
        let dx = subject.midX - target.x
        let dy = subject.midY - target.y
        if dx < -0.10 { return (.move(.left), kind, target, targetRect) }
        if dx > 0.10 { return (.move(.right), kind, target, targetRect) }
        if dy < -0.11 { return (.move(.up), kind, target, targetRect) }
        if dy > 0.11 { return (.move(.down), kind, target, targetRect) }
        if effectiveIntent == .people,
            (measurement.people.contains { !$0.faceVisible || !$0.faceReady })
        {
            return (.gaze, kind, target, targetRect)
        }
        if let exposure = exposureDirection(for: measurement.exposure) {
            return (.exposure(exposure), kind, target, targetRect)
        }
        return (.hold, kind, target, targetRect)
    }

    private static func subjectKind(for measurement: SceneMeasurement, intent: CaptureIntent) -> GuidanceSubjectKind {
        if intent == .scene { return measurement.primaryRect == nil ? .unavailable : .scene }
        switch measurement.people.count {
        case 0: return intent == .people ? .unavailable : .scene
        case 1: return .onePerson
        case 2: return .couple
        case 3...5: return .smallGroup
        default: return .unavailable
        }
    }

    private static func exposureDirection(for exposure: Double) -> ExposureDirection? {
        if exposure < 0.18 { return .brighten }
        if exposure > 0.88 { return .darken }
        return nil
    }

    private static func isSatisfied(
        _ step: GuidanceStep,
        measurement: SceneMeasurement,
        intent: CaptureIntent,
        target: CGPoint
    ) -> Bool {
        let kind = subjectKind(for: measurement, intent: intent == .auto ? (measurement.people.isEmpty ? .scene : .people) : intent)
        let rect: CGRect?
        switch kind {
        case .couple, .smallGroup: rect = measurement.group.map { upright($0.envelope) }
        default: rect = measurement.primaryRect.map(upright)
        }
        let area = rect.map { $0.width * $0.height } ?? 0
        let dx = (rect?.midX ?? target.x) - target.x
        let dy = (rect?.midY ?? target.y) - target.y
        switch step {
        case .horizon: return abs(measurement.horizonAngle ?? 0) < 0.025
        case .scale(.closer): return area > 0.075
        case .scale(.farther): return area < 0.45
        case .move(.left), .move(.right): return abs(dx) < 0.05
        case .move(.up), .move(.down): return abs(dy) < 0.055
        case .gaze: return measurement.people.allSatisfy { $0.faceVisible && $0.faceReady }
        case .spacing:
            guard let group = measurement.group else { return true }
            return group.maximumOverlap < 0.05 && group.memberSpacing.allSatisfy { $0 > 0.03 }
        case .exposure(.brighten): return measurement.exposure > 0.26
        case .exposure(.darken): return measurement.exposure < 0.80
        case .pose, .color, .hold: return true
        }
    }

    private static func materiallyContradicts(_ active: GuidanceStep, _ proposed: GuidanceStep?) -> Bool {
        guard let proposed else { return false }
        switch (active, proposed) {
        case (.move(let current), .move(let next)): return current != next
        case (.scale(let current), .scale(let next)): return current != next
        case (.exposure(let current), .exposure(let next)): return current != next
        default: return false
        }
    }

    private static func selectionPresentation(
        measurement: SceneMeasurement,
        intent: CaptureIntent,
        generation: Int
    ) -> GuidancePresentation {
        GuidancePresentation(
            sessionState: .selectingSubject,
            intent: intent,
            generation: generation,
            subjectKind: .unavailable,
            subjectID: nil,
            subjectRect: nil,
            people: peoplePresentation(measurement),
            target: CGPoint(x: 0.5, y: 0.5),
            targetRect: nil,
            movementPath: nil,
            horizonAngle: measurement.horizonAngle,
            step: nil,
            instructionKey: "guidance.findSubject",
            instruction: nil
        )
    }

    private static func presentation(
        for step: GuidanceStep,
        measurement: SceneMeasurement,
        intent: CaptureIntent,
        generation: Int,
        subjectKind: GuidanceSubjectKind,
        target: CGPoint,
        targetRect: CGRect?,
        semanticTarget: SemanticGuidanceTarget?,
        sessionState: GuidanceSessionState
    ) -> GuidancePresentation {
        let rawSubject: CGRect?
        switch subjectKind {
        case .couple, .smallGroup: rawSubject = measurement.group?.envelope
        default: rawSubject = measurement.selectedPerson?.humanRect ?? measurement.primaryRect
        }
        let subjectRect = rawSubject.map(upright)
        let movementPath: GuidancePath?
        if case .move = step, let subjectRect {
            movementPath = GuidancePath(
                start: CGPoint(x: subjectRect.midX, y: subjectRect.midY),
                end: target
            )
        } else {
            movementPath = nil
        }
        return GuidancePresentation(
            sessionState: sessionState,
            intent: intent,
            generation: generation,
            subjectKind: subjectKind,
            subjectID: measurement.selectedSubjectID,
            subjectRect: subjectRect,
            people: peoplePresentation(measurement),
            target: target,
            targetRect: targetRect,
            movementPath: movementPath,
            horizonAngle: measurement.horizonAngle,
            step: step,
            instructionKey: instructionKey(for: step),
            instruction: semanticTarget?.instruction ?? localInstruction(for: step, kind: subjectKind)
        )
    }

    private static func peoplePresentation(_ measurement: SceneMeasurement) -> [GuidancePersonPresentation] {
        measurement.people.map {
            GuidancePersonPresentation(
                id: $0.id,
                frame: upright($0.humanRect),
                faceFrame: $0.faceRect.map(upright),
                isSelected: $0.id == measurement.selectedSubjectID
            )
        }
    }

    private static func instructionKey(for step: GuidanceStep) -> String {
        switch step.direction {
        case .left: "guidance.left"
        case .right: "guidance.right"
        case .up: "guidance.up"
        case .down: "guidance.down"
        case .closer: "guidance.closer"
        case .farther: "guidance.farther"
        case .level: "guidance.level"
        case .brighten: "guidance.brighter"
        case .darken: "guidance.darker"
        case .none: "guidance.ready"
        }
    }

    private static func localInstruction(for step: GuidanceStep, kind: GuidanceSubjectKind) -> String? {
        switch step {
        case .spacing:
            return kind == .couple ? "Give each person a little more space" : "Open the group spacing slightly"
        case .gaze: return "Wait until faces are clearly visible"
        case .hold: return nil
        case .pose, .color: return nil
        default: return nil
        }
    }

    private static func upright(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }
}
