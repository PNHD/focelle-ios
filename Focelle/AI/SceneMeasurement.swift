import CoreGraphics
import Foundation

enum CaptureIntent: String, CaseIterable, Equatable, Sendable {
    case auto
    case people
    case scene
}

struct SubjectTrackID: Hashable, Sendable {
    let generation: Int
    let value: UUID

    init(generation: Int, value: UUID = UUID()) {
        self.generation = generation
        self.value = value
    }
}

enum PersonJoint: String, CaseIterable, Equatable, Sendable {
    case leftShoulder
    case rightShoulder
    case leftHip
    case rightHip
}

struct PoseJoint: Equatable, Sendable {
    let kind: PersonJoint
    let point: CGPoint
    let confidence: Double
}

struct BodyAxis: Equatable, Sendable {
    let start: CGPoint
    let end: CGPoint
    let confidence: Double
}

// This intentionally retains only the four joints needed to reason about a
// person's broad orientation. It is not a body-shaping or beauty model.
struct PersonGeometry: Equatable, Sendable {
    var id: SubjectTrackID
    var humanRect: CGRect
    var faceRect: CGRect?
    var joints: [PoseJoint]
    var shoulderAxis: BodyAxis?
    var hipAxis: BodyAxis?
    var faceVisible: Bool
    var faceReady: Bool

    init(
        id: SubjectTrackID,
        humanRect: CGRect,
        faceRect: CGRect? = nil,
        joints: [PoseJoint] = [],
        shoulderAxis: BodyAxis? = nil,
        hipAxis: BodyAxis? = nil,
        faceVisible: Bool? = nil,
        faceReady: Bool = true
    ) {
        self.id = id
        self.humanRect = humanRect
        self.faceRect = faceRect
        self.joints = joints
        self.shoulderAxis = shoulderAxis
        self.hipAxis = hipAxis
        self.faceVisible = faceVisible ?? faceRect != nil
        self.faceReady = faceReady
    }
}

struct GroupGeometry: Equatable, Sendable {
    let memberIDs: [SubjectTrackID]
    let envelope: CGRect
    let center: CGPoint
    let memberSpacing: [CGFloat]
    let maximumOverlap: CGFloat
    let visibleFaceCount: Int
    let headVerticalSpread: CGFloat

    init?(people: [PersonGeometry]) {
        guard (2...5).contains(people.count) else { return nil }
        let ordered = people.sorted {
            $0.humanRect.midX == $1.humanRect.midX
                ? $0.id.value.uuidString < $1.id.value.uuidString
                : $0.humanRect.midX < $1.humanRect.midX
        }
        guard let first = ordered.first else { return nil }
        let envelope = ordered.dropFirst().reduce(first.humanRect) { $0.union($1.humanRect) }
        let spacing = zip(ordered, ordered.dropFirst()).map {
            $1.humanRect.minX - $0.humanRect.maxX
        }
        let overlaps = ordered.enumerated().flatMap { leftIndex, left in
            ordered.dropFirst(leftIndex + 1).map { right in
                let intersection = left.humanRect.intersection(right.humanRect)
                guard !intersection.isNull else { return CGFloat.zero }
                return intersection.width * intersection.height
                    / max(min(left.humanRect.width * left.humanRect.height, right.humanRect.width * right.humanRect.height), 0.0001)
            }
        }
        let headCenters = ordered.compactMap { $0.faceRect?.midY }

        memberIDs = ordered.map(\.id)
        self.envelope = envelope
        center = CGPoint(x: envelope.midX, y: envelope.midY)
        memberSpacing = spacing
        maximumOverlap = overlaps.max() ?? 0
        visibleFaceCount = ordered.filter(\.faceVisible).count
        headVerticalSpread = (headCenters.max() ?? 0) - (headCenters.min() ?? 0)
    }
}

struct SceneGeometry: Equatable, Sendable {
    var primarySubjectRect: CGRect?
    var horizonAngle: Double?
    var horizonConfidence: Double?
    var luma: Double
}

struct SceneMeasurement: Equatable, Sendable {
    // Legacy rectangle fields remain as a compatibility boundary for the
    // existing analyzer/capture paths; `people` is the semantic source for
    // any person-aware guidance.
    var subjectRect: CGRect?
    var humanRects: [CGRect]
    var faceRects: [CGRect]
    var bodyPoseCount: Int
    var people: [PersonGeometry]
    var selectedSubjectID: SubjectTrackID?
    var salientRect: CGRect?
    var horizonAngle: Double?
    var exposure: Double
    var faceReady: Bool
    var timestamp: TimeInterval
    var scene: SceneGeometry

    init(
        subjectRect: CGRect? = nil,
        humanRects: [CGRect] = [],
        faceRects: [CGRect] = [],
        bodyPoseCount: Int = 0,
        people: [PersonGeometry] = [],
        selectedSubjectID: SubjectTrackID? = nil,
        salientRect: CGRect? = nil,
        horizonAngle: Double? = nil,
        horizonConfidence: Double? = nil,
        exposure: Double,
        faceReady: Bool = true,
        timestamp: TimeInterval
    ) {
        let retainedPeople = people.isEmpty
            ? humanRects.map {
                PersonGeometry(id: SubjectTrackID(generation: 0), humanRect: $0)
            }
            : people
        self.subjectRect = subjectRect
            ?? retainedPeople.max { $0.humanRect.width * $0.humanRect.height < $1.humanRect.width * $1.humanRect.height }?.humanRect
        self.humanRects = retainedPeople.map(\.humanRect)
        self.faceRects = faceRects.isEmpty ? retainedPeople.compactMap(\.faceRect) : faceRects
        self.bodyPoseCount = bodyPoseCount
        self.people = retainedPeople
        self.selectedSubjectID = selectedSubjectID
        self.salientRect = salientRect
        self.horizonAngle = horizonAngle
        self.exposure = exposure
        self.faceReady = faceReady
        self.timestamp = timestamp
        scene = SceneGeometry(
            primarySubjectRect: salientRect,
            horizonAngle: horizonAngle,
            horizonConfidence: horizonConfidence,
            luma: exposure
        )
    }

    var selectedPerson: PersonGeometry? {
        guard let selectedSubjectID else { return nil }
        return people.first { $0.id == selectedSubjectID }
    }

    var group: GroupGeometry? { GroupGeometry(people: people) }

    var primaryRect: CGRect? {
        selectedPerson?.humanRect
            ?? subjectRect
            ?? people.max { $0.humanRect.width * $0.humanRect.height < $1.humanRect.width * $1.humanRect.height }?.humanRect
            ?? faceRects.max { $0.width * $0.height < $1.width * $1.height }
            ?? scene.primarySubjectRect
            ?? salientRect
    }

    func person(near point: CGPoint) -> PersonGeometry? {
        let scored = people.compactMap { person -> (PersonGeometry, CGFloat)? in
            let rect = person.humanRect
            let scale = max(hypot(rect.width, rect.height), 0.0001)
            let distance = hypot(point.x - rect.midX, point.y - rect.midY) / scale
            guard rect.contains(point) || distance <= 0.65 else { return nil }
            return (person, (rect.contains(point) ? 2 : 1) - distance)
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return nil }
        // A tap between overlapping people is not sufficient identity proof.
        guard scored.dropFirst().first.map({ best.1 - $0.1 > 0.08 }) ?? true else { return nil }
        return best.0
    }

    func subject(near point: CGPoint) -> CGRect? {
        if let person = person(near: point) { return person.humanRect }
        let candidates = faceRects + [subjectRect, salientRect].compactMap { $0 }
        return candidates.min {
            hypot(point.x - $0.midX, point.y - $0.midY)
                < hypot(point.x - $1.midX, point.y - $1.midY)
        }
    }
}
