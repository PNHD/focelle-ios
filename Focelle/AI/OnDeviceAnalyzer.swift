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
    private var lastDescriptor: SceneDescriptor?
    private var lastDetectionTime = -Double.infinity
    private var lastPose3DTime = -Double.infinity
    private var lastClassificationTime = -Double.infinity
    private var lastClassifications: [String] = []
    private var identityTracker = SubjectIdentityTracker()

    func analyze(
        _ buffer: CVPixelBuffer,
        preferredSubjectPoint: CGPoint?,
        generation: Int,
        completion: @escaping @Sendable (SceneMeasurement?, SceneDescriptor?) -> Void
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
                        completion(measurement, self.lastDescriptor)
                        return
                    }
                } else if var measurement = self.lastMeasurement {
                    measurement.exposure = Self.averageLuma(pixelBuffer)
                    measurement.timestamp = now
                    self.lastMeasurement = measurement
                    completion(measurement, self.lastDescriptor)
                    return
                }
            }

            let faces = VNDetectFaceCaptureQualityRequest()
            let faceLandmarks = VNDetectFaceLandmarksRequest()
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
                try handler.perform([faces, faceLandmarks, humans, bodyPoses, horizon, saliency])
                let humanRects = humans.results?.map(\.boundingBox) ?? []
                let faceObservations = faces.results ?? []
                var measurement = SceneMeasurement(
                    subjectRect: Self.combinedRect(humanRects),
                    humanRects: humanRects,
                    faceRects: faceObservations.map(\.boundingBox),
                    bodyPoseCount: bodyPoses.results?.count ?? 0,
                    salientRect: saliency.results?
                        .first?
                        .salientObjects?
                        .max { Self.area($0.boundingBox) < Self.area($1.boundingBox) }?
                        .boundingBox,
                    horizonAngle: horizon.results?.first.map { Double($0.angle) },
                    exposure: Self.averageLuma(pixelBuffer),
                    faceReady: faceObservations.allSatisfy {
                        ($0.faceCaptureQuality ?? 0) >= 0.35
                    },
                    timestamp: now
                )
                if let point = preferredSubjectPoint,
                    let selected = measurement.subject(near: point)
                {
                    measurement.subjectRect = selected
                }

                let identity = self.associateSubject(
                    buffer: pixelBuffer,
                    measurement: &measurement,
                    preferredSubjectPoint: preferredSubjectPoint,
                    now: now
                )

                let lighting = Self.lightingInfo(pixelBuffer, subjectRect: measurement.subjectRect)
                let descriptor = SceneDescriptor(
                    subjectRect: identity?.rect ?? measurement.subjectRect,
                    subjectIdentityID: identity?.id,
                    humanRects: humanRects,
                    poseLandmarks: Self.poseLandmarks(bodyPoses.results?.first),
                    pose3D: self.pose3DLandmarks(pixelBuffer, now: now),
                    faceLandmarks: Self.faceLandmarks(faceLandmarks.results),
                    faceCaptureQuality: faceObservations.max {
                        ($0.faceCaptureQuality ?? 0) < ($1.faceCaptureQuality ?? 0)
                    }?.faceCaptureQuality.map(Double.init),
                    saliencyRect: measurement.salientRect,
                    horizonAngle: measurement.horizonAngle,
                    luma: measurement.exposure,
                    lighting: lighting,
                    blurProxy: Self.blurProxy(pixelBuffer),
                    classifications: self.classifications(
                        now: now,
                        measurement: measurement,
                        lighting: lighting
                    ),
                    generation: generation,
                    timestamp: now
                )
                self.lastDetectionTime = now
                self.lastMeasurement = measurement
                self.lastDescriptor = descriptor
                self.sequenceHandler = VNSequenceRequestHandler()
                self.tracker = measurement.primaryRect.map(Self.makeTracker)
                completion(measurement, descriptor)
            } catch {
                completion(self.lastMeasurement, self.lastDescriptor)
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
            self.lastDescriptor = nil
            self.lastDetectionTime = -.infinity
            self.lastPose3DTime = -.infinity
            self.lastClassificationTime = -.infinity
            self.lastClassifications = []
            self.identityTracker = SubjectIdentityTracker()
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

    // Selected-subject association with box-overlap and feature-print
    // evidence; never jumps to an unrelated object while identity is lost.
    private func associateSubject(
        buffer: CVPixelBuffer,
        measurement: inout SceneMeasurement,
        preferredSubjectPoint: CGPoint?,
        now: TimeInterval
    ) -> SubjectIdentity? {
        guard preferredSubjectPoint != nil || identityTracker.identity != nil else {
            return nil
        }
        let candidates = measurement.humanRects.isEmpty ? measurement.faceRects : measurement.humanRects
        guard !candidates.isEmpty else {
            _ = identityTracker.update(candidates: [], featurePrints: [], now: now)
            return identityTracker.identity
        }
        let prints = candidates.map { Self.featurePrint(buffer, rect: $0) }
        let identity = identityTracker.update(
            candidates: candidates,
            featurePrints: prints,
            now: now
        )
        if let identity {
            measurement.subjectRect = identity.rect
        }
        return identity
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
            measurement.exposure = Self.averageLuma(buffer)
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

    // 3D pose runs at ~1 Hz maximum and only when the device supports it;
    // an unsupported device fails the perform silently and yields nil.
    private func pose3DLandmarks(_ buffer: CVPixelBuffer, now: TimeInterval) -> [PoseLandmark]? {
        guard now - lastPose3DTime >= 1.0 else { return lastDescriptor?.pose3D }
        lastPose3DTime = now
        let request = VNDetectHumanBodyPose3DRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            let points = try observation.recognizedPoints(.all)
            return points.compactMap { joint, point in
                guard point.confidence > 0.2 else { return nil }
                return PoseLandmark(
                    name: joint.rawValue,
                    point: NormalizedPoint(x: point.position.x, y: point.position.y),
                    confidence: point.confidence,
                    depth: point.position.z
                )
            }
        } catch {
            return nil
        }
    }

    // Cached low-cadence classifications (~2 s), derived from lighting
    // statistics and coarse scene structure — never image content details.
    private func classifications(
        now: TimeInterval,
        measurement: SceneMeasurement,
        lighting: LightingInfo
    ) -> [String] {
        guard now - lastClassificationTime >= 2.0 else { return lastClassifications }
        lastClassificationTime = now
        var tags: [String] = []
        let luma = measurement.exposure
        if luma < 0.35 { tags.append("indoor") }
        if luma > 0.65 { tags.append("outdoor") }
        if measurement.humanRects.count == 1 { tags.append("onePerson") }
        if measurement.humanRects.count >= 2 { tags.append("group") }
        if measurement.horizonAngle != nil { tags.append("hasHorizon") }
        if lighting.contrast > 0.08 { tags.append("highContrast") }
        lastClassifications = tags
        return tags
    }

    static func poseLandmarks(_ observation: VNHumanBodyPoseObservation?) -> [PoseLandmark] {
        guard let observation,
            let points = try? observation.recognizedPoints(.all)
        else { return [] }
        return points.compactMap { joint, point in
            guard point.confidence > 0.15 else { return nil }
            return PoseLandmark(
                name: joint.rawValue,
                point: NormalizedPoint(x: point.location.x, y: point.location.y),
                confidence: point.confidence
            )
        }
    }

    static func faceLandmarks(_ observations: [VNFaceObservation]?) -> [FaceLandmark] {
        guard let observations else { return [] }
        let names: [(VNFaceLandmarkRegion2D?, String)] = [
            (observations.first?.landmarks?.leftEye, "left_eye"),
            (observations.first?.landmarks?.rightEye, "right_eye"),
            (observations.first?.landmarks?.nose, "nose"),
            (observations.first?.landmarks?.outerLips, "outer_lips"),
        ]
        let confidence = observations.first?.confidence ?? 0
        return names.compactMap { region, name in
            guard let point = region?.normalizedPoints.first else { return nil }
            return FaceLandmark(
                name: name,
                point: NormalizedPoint(x: point.x, y: point.y),
                confidence: confidence
            )
        }
    }

    // A tiny luma histogram of the subject region — association evidence
    // only, computed only for a selected subject, never logged.
    static func featurePrint(_ buffer: CVPixelBuffer, rect: CGRect) -> FeaturePrint? {
        let samples = sampledLuma(in: buffer, rect: rect)
        guard !samples.isEmpty else { return nil }
        return FeaturePrint(buckets: LightingInfo.histogram(fromLumaSamples: samples))
    }

    static func lightingInfo(_ buffer: CVPixelBuffer, subjectRect: CGRect?) -> LightingInfo {
        let samples = sampledLuma(in: buffer, rect: nil)
        let histogram = LightingInfo.histogram(fromLumaSamples: samples)
        let subjectLuma: Double?
        if let subjectRect {
            let subjectSamples = sampledLuma(in: buffer, rect: subjectRect)
            subjectLuma = subjectSamples.isEmpty ? nil : subjectSamples.reduce(0, +) / Double(subjectSamples.count)
        } else {
            subjectLuma = nil
        }
        let frameLuma = samples.isEmpty ? 0.5 : samples.reduce(0, +) / Double(samples.count)
        return LightingInfo(
            histogram: histogram,
            backlit: LightingInfo.isBacklit(subjectLuma: subjectLuma, backgroundLuma: frameLuma),
            contrast: LightingInfo.contrast(of: histogram)
        )
    }

    // 1 - mean absolute adjacent-sample difference, normalized; a softness
    // proxy, not a sharpness measurement.
    static func blurProxy(_ buffer: CVPixelBuffer) -> Double {
        let samples = sampledLuma(in: buffer, rect: nil)
        guard samples.count > 1 else { return 0.5 }
        var total = 0.0
        for index in 1..<samples.count {
            total += abs(samples[index] - samples[index - 1])
        }
        return max(0, min(1, 1 - total / Double(samples.count - 1)))
    }

    private static func sampledLuma(in buffer: CVPixelBuffer, rect: CGRect?) -> [Double] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
            let base = CVPixelBufferGetBaseAddress(buffer)
        else { return [] }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = max(min(width, height) / 24, 1)
        var samples: [Double] = []
        if let rect, rect.width > 0, rect.height > 0 {
            let x0 = max(Int(rect.minX * Double(width)), 0)
            let x1 = min(Int(rect.maxX * Double(width)), width - 1)
            let y0 = max(Int(rect.minY * Double(height)), 0)
            let y1 = min(Int(rect.maxY * Double(height)), height - 1)
            for y in Swift.stride(from: y0, through: y1, by: stride) {
                for x in Swift.stride(from: x0, through: x1, by: stride) {
                    let pixel = bytes + y * bytesPerRow + x * 4
                    samples.append(Self.luma(pixel))
                }
            }
        } else {
            for y in Swift.stride(from: 0, to: height, by: stride) {
                for x in Swift.stride(from: 0, to: width, by: stride) {
                    let pixel = bytes + y * bytesPerRow + x * 4
                    samples.append(Self.luma(pixel))
                }
            }
        }
        return samples
    }

    private static func luma(_ pixel: UnsafePointer<UInt8>) -> Double {
        (0.0722 * Double(pixel[0])
            + 0.7152 * Double(pixel[1])
            + 0.2126 * Double(pixel[2])) / 255
    }

    private static func averageLuma(_ buffer: CVPixelBuffer) -> Double {
        let samples = sampledLuma(in: buffer, rect: nil)
        return samples.isEmpty ? 0.5 : samples.reduce(0, +) / Double(samples.count)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }
}
