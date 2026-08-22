import CoreGraphics

// Bounded geometric matching is deliberately session-local. It makes tapping
// one person dependable through normal camera movement, without pretending to
// re-identify people after a long occlusion.
struct MeasurementStabilizer {
    private struct Track {
        var geometry: PersonGeometry
        var missedFrames: Int
    }

    private static let maximumMissedFrames = 3
    private static let smoothing = 0.35

    private(set) var value: SceneMeasurement?
    private var tracks: [SubjectTrackID: Track] = [:]
    private var generation: Int?

    mutating func update(_ next: SceneMeasurement, generation requestedGeneration: Int? = nil) -> SceneMeasurement {
        let activeGeneration = requestedGeneration ?? generation ?? next.people.first?.id.generation ?? 0
        if generation != activeGeneration {
            reset(generation: activeGeneration)
        }

        var result = next
        let oldValue = value
        var available = tracks
        var claimed = Set<SubjectTrackID>()
        var retainedPeople: [PersonGeometry] = []

        for candidate in next.people.sorted(by: Self.personOrder) {
            if let match = bestMatch(for: candidate, from: available, excluding: claimed) {
                var retained = candidate
                retained.id = match.key
                retained.humanRect = smooth(match.value.geometry.humanRect, candidate.humanRect)
                retained.faceRect = smooth(match.value.geometry.faceRect, candidate.faceRect)
                tracks[match.key] = Track(geometry: retained, missedFrames: 0)
                claimed.insert(match.key)
                retainedPeople.append(retained)
            } else {
                var retained = candidate
                retained.id = SubjectTrackID(generation: activeGeneration)
                tracks[retained.id] = Track(geometry: retained, missedFrames: 0)
                claimed.insert(retained.id)
                retainedPeople.append(retained)
            }
        }

        for (id, track) in available where !claimed.contains(id) {
            let missed = track.missedFrames + 1
            if missed > Self.maximumMissedFrames {
                tracks.removeValue(forKey: id)
            } else {
                tracks[id] = Track(geometry: track.geometry, missedFrames: missed)
            }
        }

        result.people = retainedPeople.sorted(by: Self.personOrder)
        result.humanRects = result.people.map(\.humanRect)
        result.faceRects = result.people.compactMap(\.faceRect)
        if let selected = next.selectedSubjectID, result.people.contains(where: { $0.id == selected }) {
            result.selectedSubjectID = selected
            result.subjectRect = result.selectedPerson?.humanRect
        } else {
            result.selectedSubjectID = nil
            result.subjectRect = smooth(oldValue?.subjectRect, next.subjectRect)
        }
        result.salientRect = smooth(oldValue?.salientRect, next.salientRect)
        result.horizonAngle = smooth(oldValue?.horizonAngle, next.horizonAngle)
        result.exposure = (oldValue?.exposure ?? next.exposure) * 0.65 + next.exposure * Self.smoothing
        result.scene.primarySubjectRect = result.salientRect
        result.scene.horizonAngle = result.horizonAngle
        result.scene.luma = result.exposure
        value = result
        generation = activeGeneration
        return result
    }

    mutating func reset(generation: Int? = nil) {
        value = nil
        tracks = [:]
        self.generation = generation
    }

    private func bestMatch(
        for candidate: PersonGeometry,
        from available: [SubjectTrackID: Track],
        excluding claimed: Set<SubjectTrackID>
    ) -> (key: SubjectTrackID, value: Track)? {
        let candidates = available
            .filter { !claimed.contains($0.key) && $0.value.missedFrames <= Self.maximumMissedFrames }
            .compactMap { entry in
                let score = matchScore(old: entry.value.geometry.humanRect, new: candidate.humanRect)
                return score.map { (entry.key, entry.value, $0) }
            }
            .sorted {
                $0.2 > $1.2
            }
        guard let best = candidates.first else { return nil }
        // Never use a UUID's random textual spelling to resolve a close
        // geometric tie. A new local track is safer than silently rebinding.
        guard candidates.dropFirst().first.map({ best.2 - $0.2 > 0.05 }) ?? true else {
            return nil
        }
        return (key: best.0, value: best.1)
    }

    private func matchScore(old: CGRect, new: CGRect) -> CGFloat? {
        let intersection = old.intersection(new)
        let intersectionArea = intersection.isNull ? 0 : intersection.width * intersection.height
        let unionArea = old.width * old.height + new.width * new.height - intersectionArea
        let iou = unionArea > 0 ? intersectionArea / unionArea : 0
        if iou >= 0.18 { return 1 + iou }

        let distance = hypot(old.midX - new.midX, old.midY - new.midY)
        guard distance <= 0.12 else { return nil }
        return 0.12 - distance
    }

    private static func personOrder(_ left: PersonGeometry, _ right: PersonGeometry) -> Bool {
        left.humanRect.midX == right.humanRect.midX
            ? left.humanRect.midY < right.humanRect.midY
            : left.humanRect.midX < right.humanRect.midX
    }

    private func smooth(_ old: CGRect?, _ new: CGRect?) -> CGRect? {
        guard let old, let new else { return new }
        return CGRect(
            x: old.origin.x * 0.65 + new.origin.x * Self.smoothing,
            y: old.origin.y * 0.65 + new.origin.y * Self.smoothing,
            width: old.width * 0.65 + new.width * Self.smoothing,
            height: old.height * 0.65 + new.height * Self.smoothing
        )
    }

    private func smooth(_ old: Double?, _ new: Double?) -> Double? {
        guard let old, let new else { return new }
        return old * 0.65 + new * Self.smoothing
    }
}
