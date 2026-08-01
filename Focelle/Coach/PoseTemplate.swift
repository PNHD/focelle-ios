import Foundation

// Versioned, license-clean numerical pose template. Every value is normalized
// geometry or a short instruction string; no photos or third-party assets.
struct PoseTemplate: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 1
    static let ownedSyntheticSource = "owned-synthetic"

    let schemaVersion: Int
    let id: String
    let category: String
    let framing: String
    let orientation: String
    let subjectCount: Int
    let cameraHints: [String]
    let landmarks: [String: NormalizedPoint]
    let targetFraming: TargetFraming
    let headroom: Double
    let faceZone: Frame
    let recommendedZoom: Double
    let contextTags: [String]
    let lightingConstraints: LightingConstraints
    let instructionVI: String
    let instructionEN: String
    let source: String

}

struct TargetFraming: Codable, Equatable, Sendable {
    // Fraction of the frame width/height the subject should occupy, plus the
    // normalized center the subject's bounding box should land on.
    let subjectWidth: Double
    let subjectHeight: Double
    let centerX: Double
    let centerY: Double

    var aspect: Double { subjectWidth / max(subjectHeight, 0.0001) }
}

struct Frame: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    func expanded(by margin: Double) -> Frame {
        Frame(
            x: x - margin,
            y: y - margin,
            width: width + margin * 2,
            height: height + margin * 2
        )
    }

    func isInsideUnitFrame() -> Bool {
        x >= 0 && y >= 0 && x + width <= 1 && y + height <= 1
    }
}

struct LightingConstraints: Codable, Equatable, Sendable {
    let minLuma: Double
    let maxLuma: Double
    let avoidBacklit: Bool
}

// Deterministic geometry validation for generated templates: joint angles,
// limb plausibility, face zone inside frame with crop safety, ground
// placement, and schema checks.
enum PoseTemplateValidation {
    static let categories: Set<String> = ["onePerson", "couple", "smallGroup", "product", "food", "scenery"]
    static let cropSafetyMargin = 0.05

    static func validate(_ template: PoseTemplate) -> Bool {
        guard template.schemaVersion == PoseTemplate.currentSchemaVersion,
            !template.id.isEmpty,
            categories.contains(template.category),
            (1...6).contains(template.subjectCount),
            template.source == PoseTemplate.ownedSyntheticSource,
            template.recommendedZoom >= 1,
            template.headroom >= 0.06,
            template.targetFraming.subjectWidth > 0,
            template.targetFraming.subjectHeight > 0,
            template.faceZone.isInsideUnitFrame(),
            template.faceZone.expanded(by: cropSafetyMargin).isInsideUnitFrame()
        else { return false }
        let points = template.landmarks
        for point in points.values where !isInsideUnitFrame(point) { return false }
        guard isGeometryPlausible(template) else { return false }
        return true
    }

    static func isGeometryPlausible(_ template: PoseTemplate) -> Bool {
        let points = template.landmarks
        let hasLegs =
            ["left_hip", "right_hip", "left_knee", "right_knee", "left_ankle", "right_ankle"]
            .allSatisfy { points[$0] != nil }
        let hasArms =
            ["left_shoulder", "right_shoulder", "left_elbow", "right_elbow", "left_hand", "right_hand"]
            .allSatisfy { points[$0] != nil }
        if hasLegs {
            for side in ["left", "right"] {
                guard let hip = points["\(side)_hip"],
                    let knee = points["\(side)_knee"],
                    let ankle = points["\(side)_ankle"]
                else { return false }
                let angle = angle(at: knee, a: hip, b: ankle)
                guard angle >= 25, angle <= 175 else { return false }
            }
        }
        if hasArms {
            for side in ["left", "right"] {
                guard let shoulder = points["\(side)_shoulder"],
                    let elbow = points["\(side)_elbow"],
                    let hand = points["\(side)_hand"]
                else { return false }
                let angle = angle(at: elbow, a: shoulder, b: hand)
                guard angle >= 10, angle <= 170 else { return false }
            }
        }
        if hasLegs, let leftShoulder = points["left_shoulder"],
            let rightShoulder = points["right_shoulder"],
            let leftHip = points["left_hip"], let rightHip = points["right_hip"]
        {
            let torso =
                Self.distance(leftShoulder, rightShoulder)
                + Self.distance(leftHip, rightHip)
            let leg =
                Self.distance(leftHip, points["left_ankle"]!)
                + Self.distance(rightHip, points["right_ankle"]!)
            let ratio = torso / max(leg, 0.0001)
            guard ratio >= 0.25, ratio <= 2.0 else { return false }
        }
        let lowestY = points.values.map(\.y).max() ?? 0
        guard lowestY <= 0.93 else { return false }
        return true
    }

    static func isInsideUnitFrame(_ point: NormalizedPoint) -> Bool {
        point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1
    }

    static func angle(at vertex: NormalizedPoint, a: NormalizedPoint, b: NormalizedPoint) -> Double {
        let v1 = (a.x - vertex.x, a.y - vertex.y)
        let v2 = (b.x - vertex.x, b.y - vertex.y)
        let dot = v1.0 * v2.0 + v1.1 * v2.1
        let length = ((v1.0 * v1.0 + v1.1 * v1.1) * (v2.0 * v2.0 + v2.1 * v2.1)).squareRoot()
        guard length > 0 else { return 0 }
        let cosine = min(max(dot / length, -1), 1)
        return acos(cosine) * 180 / .pi
    }

    static func distance(_ a: NormalizedPoint, _ b: NormalizedPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}

// Deterministic deduplication: canonical rounding plus mirror equivalence,
// then a configurable distance threshold in landmark/framing space.
enum PoseTemplateDedup {
    static func deduplicated(
        _ templates: [PoseTemplate],
        distanceThreshold: Double = 0.02
    ) -> [PoseTemplate] {
        let sorted = templates.sorted { $0.id < $1.id }
        var accepted: [PoseTemplate] = []
        var canonicalKeys: Set<String> = []
        for template in sorted {
            let key = canonicalKey(template)
            guard !canonicalKeys.contains(key) else { continue }
            if accepted.contains(where: { distance($0, template) < distanceThreshold }) {
                continue
            }
            canonicalKeys.insert(key)
            accepted.append(template)
        }
        return accepted
    }

    static func canonicalKey(_ template: PoseTemplate) -> String {
        let own = canonicalValues(template)
        let mirrored = canonicalValues(template.mirrored)
        return own <= mirrored ? own : mirrored
    }

    static func canonicalValues(_ template: PoseTemplate) -> String {
        let names = template.landmarks.keys.sorted()
        let landmarkPart = names.map { name in
            let point = template.landmarks[name]!
            return "\(name):\(Self.rounded(point.x)),\(Self.rounded(point.y))"
        }.joined(separator: ";")
        let framing = template.targetFraming
        let framingValues =
            "\(Self.rounded(framing.centerX)),\(Self.rounded(framing.centerY)),"
            + "\(Self.rounded(framing.subjectWidth)),\(Self.rounded(framing.subjectHeight))"
        return [
            template.category,
            "\(template.subjectCount)",
            framingValues,
            landmarkPart,
        ].joined(separator: "|")
    }

    static func rounded(_ value: Double, places: Int = 3) -> Double {
        let factor = pow(10, Double(places))
        return (value * factor).rounded() / factor
    }

    static func distance(_ a: PoseTemplate, _ b: PoseTemplate) -> Double {
        let names = Set(a.landmarks.keys).intersection(b.landmarks.keys)
        guard !names.isEmpty else { return 1 }
        let landmarkDistance = names.reduce(0.0) { partial, name in
            partial
                + PoseTemplateValidation.distance(a.landmarks[name]!, b.landmarks[name]!)
        } / Double(names.count)
        let framingDistance =
            abs(a.targetFraming.centerX - b.targetFraming.centerX)
            + abs(a.targetFraming.centerY - b.targetFraming.centerY)
            + abs(a.targetFraming.subjectWidth - b.targetFraming.subjectWidth)
            + abs(a.targetFraming.subjectHeight - b.targetFraming.subjectHeight)
        return landmarkDistance * 0.6 + framingDistance * 0.4
    }
}

extension PoseTemplate {
    var mirrored: PoseTemplate {
        func mirror(_ name: String) -> String {
            if name.hasPrefix("left_") { return "right_" + name.dropFirst(5) }
            if name.hasPrefix("right_") { return "left_" + name.dropFirst(6) }
            return name
        }
        let mirroredLandmarks = Dictionary(uniqueKeysWithValues: landmarks.map { key, value in
            (mirror(key), NormalizedPoint(x: 1 - value.x, y: value.y))
        })
        return PoseTemplate(
            schemaVersion: schemaVersion,
            id: id + "-mirror",
            category: category,
            framing: framing,
            orientation: orientation,
            subjectCount: subjectCount,
            cameraHints: cameraHints,
            landmarks: mirroredLandmarks,
            targetFraming: TargetFraming(
                subjectWidth: targetFraming.subjectWidth,
                subjectHeight: targetFraming.subjectHeight,
                centerX: 1 - targetFraming.centerX,
                centerY: targetFraming.centerY
            ),
            headroom: headroom,
            faceZone: Frame(
                x: 1 - faceZone.x - faceZone.width,
                y: faceZone.y,
                width: faceZone.width,
                height: faceZone.height
            ),
            recommendedZoom: recommendedZoom,
            contextTags: contextTags,
            lightingConstraints: lightingConstraints,
            instructionVI: instructionVI,
            instructionEN: instructionEN,
            source: source
        )
    }
}

struct PoseTemplateBundle: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let seedCount: Int
    let generatedCount: Int
    let generation: String
    let templates: [PoseTemplate]

    static func load(from url: URL) throws -> PoseTemplateBundle {
        try JSONDecoder().decode(PoseTemplateBundle.self, from: Data(contentsOf: url))
    }
}

// The checked-in generated bundle. Loading failure yields an empty bundle so
// the planner degrades to no local plans instead of crashing the camera.
enum PoseTemplateStore {
    static let resourceName = "PoseTemplates"
    static let resourceExtension = "json"

    static let shared: PoseTemplateBundle = load(in: .main)

    static func load(in bundle: Bundle) -> PoseTemplateBundle {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
            let loaded = try? PoseTemplateBundle.load(from: url)
        else {
            return PoseTemplateBundle(
                schemaVersion: PoseTemplate.currentSchemaVersion,
                seedCount: 0,
                generatedCount: 0,
                generation: "missing",
                templates: []
            )
        }
        return loaded
    }
}
