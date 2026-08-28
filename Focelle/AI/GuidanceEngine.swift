import CoreGraphics
import Foundation

// A deterministic, local reducer. It selects one correction from current
// Vision/device geometry and holds it until its tighter exit threshold is met.
// No cloud result is needed to keep the viewfinder useful.
struct GuidanceEngine {
    enum EffectiveSubjectIdentity: Equatable, Sendable {
        case selected(SubjectContinuityID)
        case automatic(SubjectContinuityID)
        case couple(Set<SubjectContinuityID>)
        case smallGroup(Set<SubjectContinuityID>)
        case scene(hasPrimarySubject: Bool)
        case unavailable
    }

    // One production truth for group spacing. `proposal`, `localInstruction`
    // and `isSatisfied` all classify through `spacingBand(for:kind:)`, so the
    // step that is raised, the advice it carries, and the condition that
    // clears it can never disagree or point in opposite directions.
    enum GroupSpacingBand: Equatable, Sendable {
        case tooClose
        case acceptable
        case tooFar
    }

    // Entry and exit deliberately read the same numbers: a spacing correction
    // has to be clearable by doing exactly what it asked for, in either
    // direction.
    static let maximumGroupOverlap: CGFloat = 0.10
    static let minimumMemberSpacing: CGFloat = 0.015
    static let maximumMemberSpacing: CGFloat = 0.15

    static func spacingBand(
        for group: GroupGeometry,
        kind: GuidanceSubjectKind
    ) -> GroupSpacingBand {
        if group.maximumOverlap > maximumGroupOverlap { return .tooClose }
        if group.memberSpacing.contains(where: { $0 < minimumMemberSpacing }) {
            return .tooClose
        }
        // A pair has no upper bound: two people standing apart is a framing
        // choice, not a measurable distribution error. Couple behaviour is
        // therefore unchanged by this band.
        if kind == .smallGroup,
            group.memberSpacing.contains(where: { $0 > maximumMemberSpacing })
        {
            return .tooFar
        }
        return .acceptable
    }

    private struct Context: Equatable {
        let intent: CaptureIntent
        let generation: Int
        let subject: EffectiveSubjectIdentity
        let semanticTarget: SemanticGuidanceTarget?
    }

    private var context: Context?
    // A plan that has been observed incompatible is permanently dead for this
    // engine lifetime. CameraSession also drops its retained copy immediately.
    private var invalidatedSemanticTargets: [SemanticGuidanceTarget] = []
    private var semanticBindings: [(target: SemanticGuidanceTarget, subject: EffectiveSubjectIdentity)] = []
    private(set) var state: GuidanceSessionState = .ready
    private(set) var currentPresentation: GuidancePresentation?

    mutating func update(
        _ measurement: SceneMeasurement,
        intent: CaptureIntent = .auto,
        generation: Int = 0,
        selectedSubjectID: SubjectTrackID? = nil,
        semanticTarget: SemanticGuidanceTarget? = nil
    ) -> GuidancePresentation? {
        guard state != .capturing, state != .failedRecoverable else {
            return currentPresentation
        }
        let selectedID = selectedSubjectID ?? measurement.selectedSubjectID
        var measured = measurement
        measured.selectedSubjectID = selectedID
        let subject = Self.effectiveSubjectIdentity(for: measured, intent: intent)
        let semanticTargetIsCompatible = semanticTarget.map { target in
            target.generation == generation
                && target.intent == intent
                && target.semanticSubjectIDs == Self.semanticSubjectIDs(for: subject)
        } ?? false
        let boundSubject = semanticTarget.flatMap { target in
            semanticBindings.first(where: { $0.target == target })?.subject
        }
        let continuityMatchesBinding = boundSubject.map { $0 == subject } ?? true
        if let semanticTarget, !semanticTargetIsCompatible || !continuityMatchesBinding {
            retireSemanticTarget(semanticTarget)
        }
        let activeSemanticTarget = semanticTarget.flatMap { target in
            guard semanticTargetIsCompatible,
                continuityMatchesBinding,
                !invalidatedSemanticTargets.contains(target)
            else { return nil }
            if boundSubject == nil {
                semanticBindings.append((target: target, subject: subject))
            }
            return target
        }
        let nextContext = Context(
            intent: intent,
            generation: generation,
            subject: subject,
            semanticTarget: activeSemanticTarget
        )
        if context?.semanticTarget != activeSemanticTarget {
            retireSemanticTarget(context?.semanticTarget)
        }
        if context != nextContext {
            context = nextContext
            state = .analyzing
            currentPresentation = nil
        }

        let proposal = Self.proposal(
            measurement: measured,
            intent: intent,
            generation: generation,
            semanticTarget: activeSemanticTarget
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
                semanticTarget: activeSemanticTarget,
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
                semanticTarget: activeSemanticTarget,
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
                semanticTarget: activeSemanticTarget,
                sessionState: .guiding(step)
            )
        }
        currentPresentation = presentation
        return presentation
    }

    mutating func reset() {
        retireSemanticTarget(context?.semanticTarget)
        context = nil
        currentPresentation = nil
        if state != .failedRecoverable {
            state = .ready
        }
    }

    mutating func recover() {
        retireSemanticTarget(context?.semanticTarget)
        context = nil
        currentPresentation = nil
        state = .ready
    }

    mutating func restartContext() {
        guard state != .capturing, state != .failedRecoverable else { return }
        retireSemanticTarget(context?.semanticTarget)
        context = nil
        currentPresentation = nil
        state = .analyzing
    }

    mutating func retireSemanticTarget(_ target: SemanticGuidanceTarget?) {
        guard let target, !invalidatedSemanticTargets.contains(target) else { return }
        invalidatedSemanticTargets.append(target)
        semanticBindings.removeAll { $0.target == target }
    }

    mutating func beginAnalysis() {
        guard state == .ready || state == .selectingSubject else { return }
        state = .analyzing
        currentPresentation = nil
    }

    func isSemanticTargetInvalidated(_ target: SemanticGuidanceTarget?) -> Bool {
        target.map { invalidatedSemanticTargets.contains($0) } ?? false
    }

    mutating func beginCapture() {
        retireSemanticTarget(context?.semanticTarget)
        context = nil
        state = .capturing
        currentPresentation = nil
    }

    mutating func completeCapture(recoverableFailure: Bool = false) {
        retireSemanticTarget(context?.semanticTarget)
        context = nil
        state = recoverableFailure ? .failedRecoverable : .ready
        currentPresentation = nil
    }

    // Compatibility helper for existing call sites/tests. It is still backed
    // by the reducer rather than an independent direction chooser.
    static func propose(_ measurement: SceneMeasurement) -> GuidancePresentation {
        var engine = GuidanceEngine()
        return engine.update(measurement)!
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
        if let group = measurement.group {
            switch kind {
            case .couple:
                // A pair is evaluated as a relationship: overlap, the gap
                // between the two people, both faces, then the pair envelope.
                if spacingBand(for: group, kind: .couple) != .acceptable {
                    return (.spacing, kind, target, targetRect)
                }
                if group.visibleFaceCount < 2 {
                    return (.gaze, kind, target, targetRect)
                }
            case .smallGroup:
                // A group uses distribution across the whole envelope. Extreme
                // gaps are measurable in both directions; no semantic pose
                // advice is invented.
                if spacingBand(for: group, kind: .smallGroup) != .acceptable {
                    return (.spacing, kind, target, targetRect)
                }
                if group.visibleFaceCount < measurement.people.count {
                    return (.gaze, kind, target, targetRect)
                }
            default:
                break
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

    static func effectiveSubjectIdentity(
        for measurement: SceneMeasurement,
        intent: CaptureIntent
    ) -> EffectiveSubjectIdentity {
        if intent == .scene {
            return .scene(hasPrimarySubject: measurement.primaryRect != nil)
        }
        if let selected = measurement.selectedSubjectID {
            guard let person = measurement.people.first(where: { $0.id == selected }) else {
                return .unavailable
            }
            return .selected(person.continuityID)
        }
        switch measurement.people.count {
        case 0:
            return intent == .people
                ? .unavailable
                : .scene(hasPrimarySubject: measurement.primaryRect != nil)
        case 1:
            return .automatic(measurement.people[0].continuityID)
        case 2:
            return .couple(Set(measurement.people.map(\.continuityID)))
        case 3...5:
            return .smallGroup(Set(measurement.people.map(\.continuityID)))
        default:
            return .unavailable
        }
    }

    private static func subjectKind(for measurement: SceneMeasurement, intent: CaptureIntent) -> GuidanceSubjectKind {
        switch effectiveSubjectIdentity(for: measurement, intent: intent) {
        case .selected, .automatic: return .onePerson
        case .couple: return .couple
        case .smallGroup: return .smallGroup
        case .scene(let hasPrimarySubject): return hasPrimarySubject ? .scene : .unavailable
        case .unavailable: return .unavailable
        }
    }

    private static func semanticSubjectIDs(for identity: EffectiveSubjectIdentity) -> Set<SubjectTrackID> {
        switch identity {
        case .selected(let id), .automatic(let id): return [id.trackID]
        case .couple(let ids), .smallGroup(let ids): return Set(ids.map(\.trackID))
        case .scene, .unavailable: return []
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
            return spacingBand(for: group, kind: kind) == .acceptable
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
            // Schema v2 has no typed Blueprint step, so its text cannot be
            // proven to describe this reducer-owned correction. Preserve only
            // the compatible geometry target and keep actionable copy local.
            instruction: localInstruction(
                for: step,
                kind: subjectKind,
                spacing: measurement.group.map { spacingBand(for: $0, kind: subjectKind) } ?? .acceptable
            )
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

    private static func localInstruction(
        for step: GuidanceStep,
        kind: GuidanceSubjectKind,
        spacing: GroupSpacingBand
    ) -> String? {
        switch step {
        case .spacing:
            // The advice follows the measured sign of the error, so it can
            // never ask a group that is already too spread out to open up.
            switch spacing {
            case .tooClose:
                return kind == .couple
                    ? "Give each person a little more space"
                    : "Open the group spacing slightly"
            case .tooFar:
                return "Ask the group to stand closer together"
            case .acceptable:
                return nil
            }
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
