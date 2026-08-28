@preconcurrency import CoreVideo
import Foundation
@preconcurrency import Vision

final class OnDeviceAnalyzer: @unchecked Sendable {
    private struct AssociationCandidate {
        let personIndex: Int
        let observationIndex: Int
        let score: CGFloat
    }

    private let queue = DispatchQueue(
        label: "com.pnhd.focelle.analysis",
        qos: .userInitiated
    )
    private var sequenceHandler = VNSequenceRequestHandler()
    private var tracker: VNTrackObjectRequest?
    private var lastMeasurement: SceneMeasurement?
    private var lastDetectionTime = -Double.infinity

    func analyze(
        _ buffer: CVPixelBuffer,
        preferredSubjectPoint: CGPoint?,
        completion: @escaping @Sendable (SceneMeasurement?) -> Void
    ) {
        nonisolated(unsafe) let pixelBuffer = buffer
        queue.async {
            let now = ProcessInfo.processInfo.systemUptime
            let thermallyConstrained = ProcessInfo.processInfo.thermalState != .nominal
            if Self.shouldDeferFullDetection(
                elapsed: now - self.lastDetectionTime,
                hasMeasurement: self.lastMeasurement != nil,
                thermallyConstrained: thermallyConstrained
            ) {
                if self.tracker != nil {
                    if let measurement = self.track(pixelBuffer, now: now) {
                        completion(measurement)
                        return
                    }
                } else if var measurement = self.lastMeasurement {
                    measurement.exposure = Self.averageLuma(pixelBuffer)
                    measurement.scene.luma = measurement.exposure
                    measurement.timestamp = now
                    self.lastMeasurement = measurement
                    completion(measurement)
                    return
                }
            }

            let faces = VNDetectFaceCaptureQualityRequest()
            let humans = VNDetectHumanRectanglesRequest()
            humans.upperBodyOnly = false
            let bodyPoses = VNDetectHumanBodyPoseRequest()
            let horizon = VNDetectHorizonRequest()
            let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .up
            )

            do {
                try handler.perform([faces, humans, bodyPoses, horizon, saliency])
                let humanRects = humans.results?.map(\.boundingBox) ?? []
                let faceObservations = faces.results ?? []
                let poseObservations = bodyPoses.results ?? []
                let people = Self.people(
                    humanRects: humanRects,
                    faces: faceObservations,
                    poses: poseObservations
                )
                var measurement = SceneMeasurement(
                    people: people,
                    salientRect: saliency.results?
                        .first?
                        .salientObjects?
                        .max { Self.area($0.boundingBox) < Self.area($1.boundingBox) }?
                        .boundingBox,
                    horizonAngle: horizon.results?.first.map { Double($0.angle) },
                    exposure: Self.averageLuma(pixelBuffer),
                    faceReady: people.allSatisfy(\.faceReady),
                    timestamp: now
                )
                measurement.bodyPoseCount = poseObservations.count
                if let point = preferredSubjectPoint,
                    let selected = measurement.person(near: point)
                {
                    measurement.selectedSubjectID = selected.id
                    measurement.subjectRect = selected.humanRect
                }
                self.lastDetectionTime = now
                self.lastMeasurement = measurement
                self.sequenceHandler = VNSequenceRequestHandler()
                self.tracker = measurement.primaryRect.map(Self.makeTracker)
                completion(measurement)
            } catch {
                completion(self.lastMeasurement)
            }
        }
    }

    func track(_ rect: CGRect) {
        queue.async {
            self.sequenceHandler = VNSequenceRequestHandler()
            self.tracker = Self.makeTracker(rect)
            self.lastMeasurement?.subjectRect = rect
        }
    }

    func resetTracking() {
        queue.async {
            self.sequenceHandler = VNSequenceRequestHandler()
            self.tracker = nil
            self.lastMeasurement = nil
            self.lastDetectionTime = -.infinity
        }
    }

    static func combinedRect(_ rects: [CGRect]) -> CGRect? {
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    static func shouldDeferFullDetection(
        elapsed: TimeInterval,
        hasMeasurement: Bool,
        thermallyConstrained: Bool
    ) -> Bool {
        hasMeasurement && elapsed < (thermallyConstrained ? 1.4 : 0.7)
    }

    private static func people(
        humanRects: [CGRect],
        faces: [VNFaceObservation],
        poses: [VNHumanBodyPoseObservation]
    ) -> [PersonGeometry] {
        let faceRects = faces.map(\.boundingBox)
        let poseJoints = poses.map { poseGeometry($0) }
        let faceOwners = associateFaces(faceRects, to: humanRects)
        let poseOwners = associatePoses(poseJoints, to: humanRects)
        return humanRects.indices.map { index in
            let humanRect = humanRects[index]
            let faceIndex = faceOwners[index]
            let poseIndex = poseOwners[index]
            let face = faceIndex.map { faces[$0] }
            let pose = poseIndex.map { poseJoints[$0] }
            let joints = pose ?? []
            return PersonGeometry(
                id: SubjectTrackID(generation: 0),
                humanRect: humanRect,
                faceRect: face?.boundingBox,
                joints: joints,
                shoulderAxis: axis(.leftShoulder, .rightShoulder, in: joints),
                hipAxis: axis(.leftHip, .rightHip, in: joints),
                faceVisible: face != nil,
                faceReady: face.map { ($0.faceCaptureQuality ?? 0) >= 0.35 } ?? false
            )
        }
    }

    // The association boundary retains only value geometry. Vision observations
    // never enter SceneMeasurement or its presentation state.
    static func associateFaces(_ faces: [CGRect], to people: [CGRect]) -> [Int: Int] {
        associate(
            observations: faces.enumerated().map { (index: $0.offset, rect: $0.element) },
            to: people
        )
    }

    static func associatePoses(_ poses: [[PoseJoint]], to people: [CGRect]) -> [Int: Int] {
        let bounds = poses.map { joints -> CGRect? in
            // A pose needs at least two independently credible joints before
            // it can claim a person slot. A weak point cloud is not evidence
            // of person ownership.
            let credible = joints.filter { $0.confidence >= 0.35 }
            guard credible.count >= 2 else { return nil }
            guard let first = credible.first else { return nil }
            let bounds = credible.dropFirst().reduce(CGRect(origin: first.point, size: .zero)) {
                $0.union(CGRect(origin: $1.point, size: .zero))
            }
            // Joint geometry is often line-like (for example, shoulders at
            // the same y). Give it a small normalized footprint so the same
            // absolute association floor can evaluate it meaningfully.
            return bounds.insetBy(dx: -0.01, dy: -0.01)
        }
        return associate(
            observations: bounds.enumerated().compactMap { index, rect in
                rect.map { (index: index, rect: $0) }
            },
            to: people
        )
    }

    private static func associate(
        observations: [(index: Int, rect: CGRect)],
        to people: [CGRect]
    ) -> [Int: Int] {
        let confidenceMargin: CGFloat = 0.08
        let maximumNormalizedDistance: CGFloat = 0.24
        let minimumContainedOverlap: CGFloat = 0.50
        let minimumNearbyOverlap: CGFloat = 0.35
        var uniqueCandidates: [AssociationCandidate] = []
        for observationInput in observations {
            let observationIndex = observationInput.index
            let observation = observationInput.rect
            let center = CGPoint(x: observation.midX, y: observation.midY)
            let candidates = people.enumerated().compactMap { personIndex, person -> AssociationCandidate? in
                let intersection = observation.intersection(person)
                let overlap = intersection.isNull || area(observation) <= 0
                    ? 0
                    : area(intersection) / area(observation)
                let normalizedDistance = hypot(center.x - person.midX, center.y - person.midY)
                    / max(hypot(person.width, person.height), 0.0001)
                let contained = person.contains(center) && overlap >= minimumContainedOverlap
                let nearby = overlap >= minimumNearbyOverlap
                    && normalizedDistance <= maximumNormalizedDistance
                // An edge sliver alone cannot establish ownership. Both the
                // absolute floor and the competing-candidate margin below are
                // required before Vision geometry enters the domain model.
                guard contained || nearby else {
                    return nil
                }
                let score = (contained ? 2 : 0) + overlap
                    + max(0, maximumNormalizedDistance - normalizedDistance)
                return AssociationCandidate(
                    personIndex: personIndex,
                    observationIndex: observationIndex,
                    score: score
                )
            }.sorted { $0.score > $1.score }
            guard let best = candidates.first,
                candidates.dropFirst().first.map({ best.score - $0.score > confidenceMargin }) ?? true
            else { continue }
            uniqueCandidates.append(best)
        }

        // If two observations have indistinguishably good ownership of one
        // person, leave both unmatched instead of duplicating geometry.
        let ambiguousPeople = Set(
            Dictionary(grouping: uniqueCandidates, by: \.personIndex).compactMap { _, candidates in
                guard candidates.count > 1,
                    let first = candidates.sorted(by: { $0.score > $1.score }).first,
                    let second = candidates.sorted(by: { $0.score > $1.score }).dropFirst().first,
                    first.score - second.score <= confidenceMargin
                else { return nil }
                return first.personIndex
            }
        )
        var owners: [Int: Int] = [:]
        for candidate in uniqueCandidates.sorted(by: { $0.score > $1.score })
            where !ambiguousPeople.contains(candidate.personIndex)
        {
            guard owners[candidate.personIndex] == nil else { continue }
            owners[candidate.personIndex] = candidate.observationIndex
        }
        return owners
    }

    private static func poseGeometry(_ observation: VNHumanBodyPoseObservation) -> [PoseJoint] {
        PersonJoint.allCases.compactMap { kind in
            let joint: VNHumanBodyPoseObservation.JointName
            switch kind {
            case .leftShoulder: joint = .leftShoulder
            case .rightShoulder: joint = .rightShoulder
            case .leftHip: joint = .leftHip
            case .rightHip: joint = .rightHip
            }
            guard let point = try? observation.recognizedPoint(joint), point.confidence >= 0.20 else {
                return nil
            }
            return PoseJoint(kind: kind, point: point.location, confidence: Double(point.confidence))
        }
    }

    private static func axis(_ first: PersonJoint, _ second: PersonJoint, in joints: [PoseJoint]) -> BodyAxis? {
        guard let start = joints.first(where: { $0.kind == first }),
            let end = joints.first(where: { $0.kind == second })
        else { return nil }
        return BodyAxis(start: start.point, end: end.point, confidence: min(start.confidence, end.confidence))
    }

    private func track(_ buffer: CVPixelBuffer, now: TimeInterval) -> SceneMeasurement? {
        guard let tracker else { return nil }
        do {
            try sequenceHandler.perform([tracker], on: buffer, orientation: .up)
            guard let observation = tracker.results?.first as? VNDetectedObjectObservation,
                observation.confidence >= 0.35,
                observation.boundingBox.width > 0,
                observation.boundingBox.height > 0,
                var measurement = lastMeasurement
            else {
                self.tracker = nil
                return nil
            }
            tracker.inputObservation = observation
            measurement.subjectRect = observation.boundingBox
            if let selected = measurement.selectedSubjectID,
                let index = measurement.people.firstIndex(where: { $0.id == selected })
            {
                measurement.people[index].humanRect = observation.boundingBox
                measurement.humanRects = measurement.people.map(\.humanRect)
            }
            measurement.exposure = Self.averageLuma(buffer)
            measurement.scene.luma = measurement.exposure
            measurement.timestamp = now
            lastMeasurement = measurement
            return measurement
        } catch {
            self.tracker = nil
            return nil
        }
    }

    private static func makeTracker(_ rect: CGRect) -> VNTrackObjectRequest {
        let request = VNTrackObjectRequest(
            detectedObjectObservation: VNDetectedObjectObservation(boundingBox: rect)
        )
        request.trackingLevel = .fast
        return request
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private static func averageLuma(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
            let base = CVPixelBufferGetBaseAddress(buffer)
        else { return 0.5 }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = max(min(width, height) / 24, 1)
        var total = 0.0
        var count = 0

        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let pixel = bytes + y * bytesPerRow + x * 4
                total +=
                    (0.0722 * Double(pixel[0])
                        + 0.7152 * Double(pixel[1])
                        + 0.2126 * Double(pixel[2])) / 255
                count += 1
            }
        }
        return count == 0 ? 0.5 : total / Double(count)
    }
}
