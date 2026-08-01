import Foundation

// One of the three local plans produced by the deterministic planner.
struct CoachPlan: Equatable, Sendable, Identifiable {
    let id: String
    let templateID: String
    let titleVI: String
    let titleEN: String
    let targetFraming: TargetFraming
    let recommendedZoom: Double
    let recommendedExposureBias: Double
    let instructionVI: String
    let instructionEN: String
    let score: Double
    let motion: Double
}

// The mandatory zoom/exposure contract. Analyze snapshots a baseline and only
// creates plans; Apply uses absolute values; Undo restores the exact baseline;
// a capability-generation change invalidates the session; repeated
// Analyze/Apply cycles cannot compound or drift.
struct PlanSession: Equatable, Sendable {
    let baselineZoom: Double
    let baselineExposureBias: Double
    let appliedZoom: Double?
    let appliedExposureBias: Double?
    let capabilityGeneration: Int

    init(
        baselineZoom: Double,
        baselineExposureBias: Double,
        capabilityGeneration: Int
    ) {
        self.baselineZoom = baselineZoom
        self.baselineExposureBias = baselineExposureBias
        self.appliedZoom = nil
        self.appliedExposureBias = nil
        self.capabilityGeneration = capabilityGeneration
    }

    private init(
        baselineZoom: Double,
        baselineExposureBias: Double,
        appliedZoom: Double?,
        appliedExposureBias: Double?,
        capabilityGeneration: Int
    ) {
        self.baselineZoom = baselineZoom
        self.baselineExposureBias = baselineExposureBias
        self.appliedZoom = appliedZoom
        self.appliedExposureBias = appliedExposureBias
        self.capabilityGeneration = capabilityGeneration
    }

    func isValid(for generation: Int) -> Bool {
        generation == capabilityGeneration
    }

    // Absolute values: what is passed is what will be set, never added to the
    // baseline. nil keeps the current value unchanged.
    func applying(zoom: Double?, exposureBias: Double?) -> PlanSession {
        PlanSession(
            baselineZoom: baselineZoom,
            baselineExposureBias: baselineExposureBias,
            appliedZoom: zoom ?? appliedZoom,
            appliedExposureBias: exposureBias ?? appliedExposureBias,
            capabilityGeneration: capabilityGeneration
        )
    }

    var undo: (zoom: Double, exposureBias: Double) {
        (baselineZoom, baselineExposureBias)
    }

    func undoing() -> PlanSession {
        PlanSession(
            baselineZoom: baselineZoom,
            baselineExposureBias: baselineExposureBias,
            appliedZoom: nil,
            appliedExposureBias: nil,
            capabilityGeneration: capabilityGeneration
        )
    }
}
