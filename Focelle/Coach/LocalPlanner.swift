import Foundation

enum FramingIntent: String, Equatable, Sendable {
    case portrait
    case fullBody
    case group
    case product
    case food
    case scenery
}

// Deterministic local planner: candidate retrieval → hard rejection →
// scoring → diversity selection. Everything works offline with no tunable
// claims of optimality — the weights are documented defaults.
enum LocalPlanner {
    struct Capabilities: Equatable, Sendable {
        let maxZoom: Double
        let aspectRatio: Double
    }

    // Experimental features stay at zero weight in Batch A.
    static let aestheticsWeight = 0.0
    static let affinityWeight = 0.0
    static let embeddingWeight = 0.0

    static func plan(
        scene: SceneDescriptor,
        intent: FramingIntent,
        templates: [PoseTemplate],
        capabilities: Capabilities,
        selectedSubject: CGRect?
    ) -> [CoachPlan] {
        let candidates = templates.filter { template in
            let countMatches: Bool
            if let expectedCount = subjectCount(for: intent) {
                countMatches = template.subjectCount == expectedCount
            } else {
                countMatches = template.subjectCount >= 2
            }
            return countMatches
                && !isHardRejected(
                    template,
                    scene: scene,
                    intent: intent,
                    capabilities: capabilities,
                    selectedSubject: selectedSubject
                )
        }
        guard !candidates.isEmpty else { return [] }

        let scored = candidates.map { template in
            let score = score(template, scene: scene, intent: intent, capabilities: capabilities)
            let motion = min(
                1,
                abs(template.recommendedZoom - 1) / max(capabilities.maxZoom, 1)
            )
            return (
                template: template,
                plan: makePlan(
                    id: "unassigned",
                    template: template,
                    score: score,
                    motion: motion
                )
            )
        }
        let primary = scored.max { $0.score < $1.score }!
        let safe = scored.min { $0.plan.motion < $1.plan.motion }!
        let rankedByDiversity = scored.sorted {
            maxMinDistance($0.plan, from: [primary.plan, safe.plan])
                > maxMinDistance($1.plan, from: [primary.plan, safe.plan])
        }
        let creative =
            rankedByDiversity.first {
                $0.template.id != primary.template.id && $0.template.id != safe.template.id
            } ?? rankedByDiversity[0]

        let plans = [
            withID(primary, "primary", titleVI: "Đẹp nhất", titleEN: "Best"),
            withID(safe, "safe", titleVI: "An toàn", titleEN: "Safe"),
            withID(creative, "creative", titleVI: "Sáng tạo", titleEN: "Creative"),
        ]
        return deduplicatedIDs(plans)
    }

    static func subjectCount(for intent: FramingIntent) -> Int? {
        switch intent {
        case .portrait, .fullBody, .product, .food, .scenery: 1
        case .group: nil
        }
    }

    // Hard constraints run before any scoring; an aesthetic score can never
    // override them.
    static func isHardRejected(
        _ template: PoseTemplate,
        scene: SceneDescriptor,
        intent: FramingIntent,
        capabilities: Capabilities,
        selectedSubject: CGRect?
    ) -> Bool {
        guard PoseTemplateValidation.validate(template) else { return true }
        if template.recommendedZoom > capabilities.maxZoom { return true }

        let frame = template.targetFraming
        let halfWidth = frame.subjectWidth / 2
        let halfHeight = frame.subjectHeight / 2
        if frame.centerX - halfWidth < 0 || frame.centerX + halfWidth > 1
            || frame.centerY - halfHeight < 0 || frame.centerY + halfHeight > 1
        {
            return true
        }

        if scene.hasPerson, intent == .portrait || intent == .fullBody || intent == .group {
            let confidentLandmarks = scene.poseLandmarks.filter { $0.confidence >= 0.25 }
            if confidentLandmarks.count < 2 { return true }
        }

        if let selectedSubject {
            let overlaps = scene.humanRects.contains {
                SubjectIdentityTracker.intersectionOverUnion($0, selectedSubject) >= 0.2
            }
            if scene.hasPerson, !overlaps { return true }
        }

        if scene.hasFace, let nose = scene.faceLandmarks.first(where: { $0.name == "nose" }) {
            let faceZone = template.faceZone
            let inside =
                nose.point.x >= faceZone.x && nose.point.x <= faceZone.x + faceZone.width
                && nose.point.y >= faceZone.y && nose.point.y <= faceZone.y + faceZone.height
            if !inside { return true }
        }
        return false
    }

    static func score(
        _ template: PoseTemplate,
        scene: SceneDescriptor,
        intent: FramingIntent,
        capabilities: Capabilities
    ) -> Double {
        let poseAlignment = poseAlignment(template, scene: scene)
        let framingFit = framingFit(template, scene: scene)
        let motion = 1 - min(1, abs(template.recommendedZoom - 1) / max(capabilities.maxZoom, 1))
        let contextMatch = contextMatch(template, intent: intent)
        let faceQuality = scene.faceCaptureQuality.map { min(max($0, 0), 1) } ?? 0.5
        let lighting = lightingFeasibility(template, scene: scene)
        let intentFit = intentMatchesCategory(intent, category: template.category) ? 1 : 0.5

        return poseAlignment * 0.25
            + framingFit * 0.2
            + motion * 0.15
            + contextMatch * 0.15
            + faceQuality * 0.1
            + lighting * 0.1
            + intentFit * 0.05
            + aestheticsWeight
            + affinityWeight
            + embeddingWeight
    }

    static func poseAlignment(_ template: PoseTemplate, scene: SceneDescriptor) -> Double {
        let names = Set(template.landmarks.keys).intersection(scene.poseLandmarks.map(\.name))
        guard !names.isEmpty else { return 0.5 }
        let total = names.reduce(0.0) { partial, name in
            guard let templatePoint = template.landmarks[name],
                let scenePoint = scene.poseLandmarks.first(where: { $0.name == name })?.point
            else { return partial }
            let distance = PoseTemplateValidation.distance(templatePoint, scenePoint)
            return partial + max(0, 1 - distance * 2.5)
        }
        return total / Double(names.count)
    }

    static func framingFit(_ template: PoseTemplate, scene: SceneDescriptor) -> Double {
        guard let subject = scene.subjectRect else { return 0.5 }
        let framing = template.targetFraming
        let centerDistance =
            abs(framing.centerX - Double(subject.midX))
            + abs(framing.centerY - Double(subject.midY))
        let sizeDistance =
            abs(framing.subjectWidth - Double(subject.width))
            + abs(framing.subjectHeight - Double(subject.height))
        return max(0, 1 - centerDistance * 2 - sizeDistance)
    }

    static func contextMatch(_ template: PoseTemplate, intent: FramingIntent) -> Double {
        let tags = template.contextTags
        guard !tags.isEmpty else { return 0.5 }
        let intentTag = intent.rawValue
        return tags.contains(intentTag) ? 1 : 0.25
    }

    static func lightingFeasibility(_ template: PoseTemplate, scene: SceneDescriptor) -> Double {
        let constraints = template.lightingConstraints
        let luma = scene.luma
        if luma < constraints.minLuma || luma > constraints.maxLuma { return 0.15 }
        if constraints.avoidBacklit, scene.lighting.backlit { return 0.15 }
        return 1
    }

    static func intentMatchesCategory(_ intent: FramingIntent, category: String) -> Bool {
        switch intent {
        case .portrait, .fullBody: category == "onePerson"
        case .group: category == "couple" || category == "smallGroup"
        case .product: category == "product"
        case .food: category == "food"
        case .scenery: category == "scenery"
        }
    }

    static func diversityDistance(_ a: CoachPlan, _ b: CoachPlan) -> Double {
        let aFrame = a.targetFraming
        let bFrame = b.targetFraming
        return abs(aFrame.centerX - bFrame.centerX)
            + abs(aFrame.centerY - bFrame.centerY)
            + abs(aFrame.subjectWidth - bFrame.subjectWidth)
            + abs(aFrame.subjectHeight - bFrame.subjectHeight)
            + abs(a.recommendedZoom - b.recommendedZoom)
    }

    static func maxMinDistance(_ candidate: CoachPlan, from others: [CoachPlan]) -> Double {
        others.map { diversityDistance(candidate, $0) }.min() ?? 1
    }

    private static func makePlan(
        id: String,
        template: PoseTemplate,
        score: Double,
        motion: Double
    ) -> CoachPlan {
        CoachPlan(
            id: id,
            templateID: template.id,
            titleVI: "",
            titleEN: "",
            targetFraming: template.targetFraming,
            recommendedZoom: template.recommendedZoom,
            recommendedExposureBias: 0,
            instructionVI: template.instructionVI,
            instructionEN: template.instructionEN,
            score: score,
            motion: motion
        )
    }

    private static func withID(
        _ entry: (template: PoseTemplate, plan: CoachPlan),
        _ id: String,
        titleVI: String,
        titleEN: String
    ) -> CoachPlan {
        CoachPlan(
            id: id,
            templateID: entry.template.id,
            titleVI: titleVI,
            titleEN: titleEN,
            targetFraming: entry.plan.targetFraming,
            recommendedZoom: entry.plan.recommendedZoom,
            recommendedExposureBias: entry.plan.recommendedExposureBias,
            instructionVI: entry.plan.instructionVI,
            instructionEN: entry.plan.instructionEN,
            score: entry.plan.score,
            motion: entry.plan.motion
        )
    }

    private static func deduplicatedIDs(_ plans: [CoachPlan]) -> [CoachPlan] {
        var seen: Set<String> = []
        return plans.filter { seen.insert($0.id).inserted }
    }
}

// Batch A boundary (section F): aesthetics scoring is benchmark-first. The
// protocol is the only surface; the concrete adapter is deferred and the
// planner weight stays zero.
protocol VisionAestheticsScoring: Sendable {
    func score(candidate: PoseTemplate, scene: SceneDescriptor) async -> Double?
}
