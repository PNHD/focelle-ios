@preconcurrency import CoreVideo
import Foundation
@preconcurrency import Vision

final class OnDeviceAnalyzer: @unchecked Sendable {
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
        humanRects.map { humanRect in
            let face = faces
                .filter { !$0.boundingBox.intersection(humanRect).isNull }
                .max { area($0.boundingBox.intersection(humanRect)) < area($1.boundingBox.intersection(humanRect)) }
            let pose = poses
                .map { poseGeometry($0) }
                .min { poseDistance($0, to: humanRect) < poseDistance($1, to: humanRect) }
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

    private static func poseDistance(_ joints: [PoseJoint], to rect: CGRect) -> CGFloat {
        guard !joints.isEmpty else { return .greatestFiniteMagnitude }
        let center = CGPoint(
            x: joints.map(\.point.x).reduce(0, +) / CGFloat(joints.count),
            y: joints.map(\.point.y).reduce(0, +) / CGFloat(joints.count)
        )
        return hypot(center.x - rect.midX, center.y - rect.midY)
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
