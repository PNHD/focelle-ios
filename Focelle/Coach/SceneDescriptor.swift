import CoreGraphics
import Foundation

// A normalized point inside the frame. Vision's normalized coordinates are
// bottom-left origin; every consumer that draws them converts once at the
// presentation layer, exactly like the existing guidance overlay.
struct NormalizedPoint: Equatable, Sendable, Codable {
    var x: Double
    var y: Double
}

struct PoseLandmark: Equatable, Sendable {
    let name: String
    let point: NormalizedPoint
    let confidence: Double
    // Depth from availability-gated 3D pose; nil for 2D landmarks.
    let depth: Double?

    init(
        name: String,
        point: NormalizedPoint,
        confidence: Double,
        depth: Double? = nil
    ) {
        self.name = name
        self.point = point
        self.confidence = confidence
        self.depth = depth
    }
}

struct FaceLandmark: Equatable, Sendable {
    let name: String
    let point: NormalizedPoint
    let confidence: Double
}

struct LightingInfo: Equatable, Sendable {
    // Eight luma buckets (0.0...1.0), normalized to sum 1.
    let histogram: [Double]
    let backlit: Bool
    // Standard deviation of the bucket probabilities — a cheap contrast proxy.
    let contrast: Double

    static func histogram(fromLumaSamples samples: [Double]) -> [Double] {
        guard !samples.isEmpty else { return Array(repeating: 0, count: 8) }
        var buckets = Array(repeating: 0.0, count: 8)
        for sample in samples {
            let index = min(max(Int(sample * 8), 0), 7)
            buckets[index] += 1
        }
        let total = buckets.reduce(0, +)
        return buckets.map { $0 / total }
    }

    static func contrast(of histogram: [Double]) -> Double {
        let mean = histogram.reduce(0, +) / Double(max(histogram.count, 1))
        let variance = histogram.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (variance / Double(max(histogram.count, 1))).squareRoot()
    }

    static func isBacklit(subjectLuma: Double?, backgroundLuma: Double) -> Bool {
        guard let subjectLuma else { return false }
        return backgroundLuma - subjectLuma > 0.25
    }
}

// The structured, privacy-safe output of the on-device analysis pipeline.
// Contains normalized geometry and scalars only — never image bytes, face
// textures, or reconstructable scene data.
struct SceneDescriptor: Equatable, Sendable {
    let subjectRect: CGRect?
    let subjectIdentityID: Int?
    let humanRects: [CGRect]
    let poseLandmarks: [PoseLandmark]
    // Availability-gated 3D pose, run at low cadence; nil when unsupported.
    let pose3D: [PoseLandmark]?
    let faceLandmarks: [FaceLandmark]
    let faceCaptureQuality: Double?
    let saliencyRect: CGRect?
    let horizonAngle: Double?
    let luma: Double
    let lighting: LightingInfo
    // 1 - normalized micro-contrast; higher means softer (more blurred).
    let blurProxy: Double
    let classifications: [String]
    let generation: Int
    let timestamp: TimeInterval

    var hasPerson: Bool { !humanRects.isEmpty }
    var hasFace: Bool { faceCaptureQuality != nil }

    static func isCurrent(generation: Int, currentGeneration: Int) -> Bool {
        generation == currentGeneration
    }
}

// A tiny deterministic luma fingerprint of the selected subject's region.
// Used only for subject association, never stored or logged.
struct FeaturePrint: Equatable, Sendable {
    let buckets: [Double]

    static func cosineSimilarity(_ a: FeaturePrint, _ b: FeaturePrint) -> Double {
        let count = min(a.buckets.count, b.buckets.count)
        guard count > 0 else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for index in 0..<count {
            dot += a.buckets[index] * b.buckets[index]
            normA += a.buckets[index] * a.buckets[index]
            normB += b.buckets[index] * b.buckets[index]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}

struct SubjectIdentity: Equatable, Sendable {
    let id: Int
    let rect: CGRect
    let featurePrint: FeaturePrint?
    let lastSeen: TimeInterval
}

// Deterministic selected-subject association across full detections and
// temporary tracking loss. A candidate is only adopted when box overlap or
// feature-print evidence says it is the same subject; otherwise the previous
// subject is preserved briefly, then reported lost — never replaced by an
// unrelated salient object.
struct SubjectIdentityTracker: Equatable, Sendable {
    private(set) var identity: SubjectIdentity?
    let preservationInterval: TimeInterval

    init(preservationInterval: TimeInterval = 0.8) {
        self.preservationInterval = preservationInterval
    }

    mutating func update(
        candidates: [CGRect],
        featurePrints: [FeaturePrint?],
        now: TimeInterval
    ) -> SubjectIdentity? {
        guard let identity else {
            guard let first = candidates.first else { return nil }
            let adopted = SubjectIdentity(
                id: 1,
                rect: first,
                featurePrint: featurePrints.first ?? nil,
                lastSeen: now
            )
            self.identity = adopted
            return adopted
        }
        if let match = Self.bestMatch(
            identity: identity,
            candidates: candidates,
            featurePrints: featurePrints
        ) {
            let adopted = SubjectIdentity(
                id: identity.id,
                rect: match.rect,
                featurePrint: match.featurePrint,
                lastSeen: now
            )
            self.identity = adopted
            return adopted
        }
        guard now - identity.lastSeen <= preservationInterval else {
            self.identity = nil
            return nil
        }
        return identity
    }

    func reset() -> SubjectIdentityTracker {
        SubjectIdentityTracker(preservationInterval: preservationInterval)
    }

    static func bestMatch(
        identity: SubjectIdentity,
        candidates: [CGRect],
        featurePrints: [FeaturePrint?]
    ) -> (rect: CGRect, featurePrint: FeaturePrint?)? {
        let prints =
            featurePrints
            + [FeaturePrint?](
                repeating: nil,
                count: max(candidates.count - featurePrints.count, 0)
            )
        let indexed = zip(candidates, prints)
        var best: (rect: CGRect, featurePrint: FeaturePrint?, overlap: Double, similarity: Double)?
        for (rect, featurePrint) in indexed {
            let overlap = Self.intersectionOverUnion(identity.rect, rect)
            let similarity =
                (identity.featurePrint).flatMap { a in
                    featurePrint.map { FeaturePrint.cosineSimilarity(a, $0) }
                } ?? 0
            guard overlap >= 0.35 || (identity.featurePrint != nil && similarity >= 0.92) else { continue }
            if best == nil || overlap > best!.overlap {
                best = (
                    rect: rect,
                    featurePrint: featurePrint,
                    overlap: overlap,
                    similarity: similarity
                )
            }
        }
        return best.map { (rect: $0.rect, featurePrint: $0.featurePrint) }
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let union = a.union(b)
        guard !union.isEmpty else { return 0 }
        return Double(intersection.width * intersection.height / (union.width * union.height))
    }
}

// Deterministic low-pass stabilization over descriptor scalars and subject
// bounds; landmark positions follow the latest detection once identity is
// associated. Pure value type so behavior is testable without hardware.
struct DescriptorStabilizer: Equatable, Sendable {
    private(set) var last: SceneDescriptor?

    mutating func update(_ descriptor: SceneDescriptor) -> SceneDescriptor {
        defer { last = descriptor }
        guard let last else { return descriptor }
        let smoothedLuma = Self.ema(last.luma, descriptor.luma)
        let smoothedQuality = Self.ema(
            last.faceCaptureQuality ?? descriptor.faceCaptureQuality ?? 0,
            descriptor.faceCaptureQuality ?? 0
        )
        let smoothedContrast = Self.ema(
            last.lighting.contrast,
            descriptor.lighting.contrast
        )
        let lighting = LightingInfo(
            histogram: descriptor.lighting.histogram,
            backlit: descriptor.lighting.backlit,
            contrast: smoothedContrast
        )
        let quality =
            descriptor.faceCaptureQuality == nil
            ? descriptor.faceCaptureQuality
            : smoothedQuality
        return SceneDescriptor(
            subjectRect: Self.ema(last.subjectRect, descriptor.subjectRect),
            subjectIdentityID: descriptor.subjectIdentityID,
            humanRects: descriptor.humanRects,
            poseLandmarks: descriptor.poseLandmarks,
            pose3D: descriptor.pose3D,
            faceLandmarks: descriptor.faceLandmarks,
            faceCaptureQuality: quality,
            saliencyRect: descriptor.saliencyRect,
            horizonAngle: descriptor.horizonAngle,
            luma: smoothedLuma,
            lighting: lighting,
            blurProxy: Self.ema(last.blurProxy, descriptor.blurProxy),
            classifications: descriptor.classifications,
            generation: descriptor.generation,
            timestamp: descriptor.timestamp
        )
    }

    static func ema(_ previous: Double, _ current: Double, factor: Double = 0.5) -> Double {
        previous + (current - previous) * factor
    }

    static func ema(_ previous: CGRect?, _ current: CGRect?) -> CGRect? {
        guard let previous, let current else { return current }
        return CGRect(
            x: ema(Double(previous.minX), Double(current.minX)),
            y: ema(Double(previous.minY), Double(current.minY)),
            width: ema(Double(previous.width), Double(current.width)),
            height: ema(Double(previous.height), Double(current.height))
        )
    }
}
