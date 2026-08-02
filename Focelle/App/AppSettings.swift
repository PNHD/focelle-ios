import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var onDeviceOnly: Bool {
        didSet { defaults.set(onDeviceOnly, forKey: "onDeviceOnly") }
    }
    @Published var analyticsEnabled: Bool {
        didSet { defaults.set(analyticsEnabled, forKey: "analyticsEnabled") }
    }
    @Published var guidanceEnabled: Bool {
        didSet { defaults.set(guidanceEnabled, forKey: "guidanceEnabled") }
    }
    // Experimental local Coach V2; default OFF so FCL-M1 behavior is the
    // fallback until the batch is physically validated.
    @Published var coachV2Enabled: Bool {
        didSet { defaults.set(coachV2Enabled, forKey: "coachV2Enabled") }
    }
    // Benchmark-first aesthetics experiments; no production effect in Batch A.
    @Published var aestheticsEnabled: Bool {
        didSet { defaults.set(aestheticsEnabled, forKey: "aestheticsEnabled") }
    }
    @Published var voiceGuidance: Bool {
        didSet { defaults.set(voiceGuidance, forKey: "voiceGuidance") }
    }
    @Published var autoCapture: Bool {
        didSet { defaults.set(autoCapture, forKey: "autoCapture") }
    }
    @Published var saveOriginal: Bool {
        didSet { defaults.set(saveOriginal, forKey: "saveOriginal") }
    }
    @Published var saveLocation: Bool {
        didSet { defaults.set(saveLocation, forKey: "saveLocation") }
    }
    // The single persisted source of truth for the requested resolution tier.
    // CameraSession.resolution is only ever a mirror of this value (see
    // CameraView), so Settings and the camera toolbar can't drift apart.
    @Published var requestedResolution: CameraResolution {
        didSet { defaults.set(requestedResolution.rawValue, forKey: Self.requestedResolutionKey) }
    }

    private static let requestedResolutionKey = "requestedResolution"
    private static let legacyMaximumResolutionKey = "maximumResolution"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onDeviceOnly = defaults.bool(forKey: "onDeviceOnly")
        analyticsEnabled = defaults.object(forKey: "analyticsEnabled") as? Bool ?? true
        guidanceEnabled = defaults.object(forKey: "guidanceEnabled") as? Bool ?? true
        coachV2Enabled = defaults.bool(forKey: "coachV2Enabled")
        aestheticsEnabled = defaults.bool(forKey: "aestheticsEnabled")
        voiceGuidance = defaults.bool(forKey: "voiceGuidance")
        autoCapture = defaults.bool(forKey: "autoCapture")
        saveOriginal = defaults.bool(forKey: "saveOriginal")
        saveLocation = defaults.bool(forKey: "saveLocation")

        let newRawValue = defaults.string(forKey: Self.requestedResolutionKey)
        let legacyValue = defaults.object(forKey: Self.legacyMaximumResolutionKey) as? Bool
        requestedResolution = Self.migratedResolution(newRawValue: newRawValue, legacyValue: legacyValue)
        if newRawValue == nil {
            // First read since upgrading: persist the migrated value immediately
            // so it — not the legacy Bool — is authoritative from here on, and
            // this branch never runs again (idempotent). Only drop the legacy
            // key once its value has actually been carried across.
            defaults.set(requestedResolution.rawValue, forKey: Self.requestedResolutionKey)
            defaults.removeObject(forKey: Self.legacyMaximumResolutionKey)
        }
    }

    // A genuine new-format value always wins; otherwise the legacy Bool (if
    // it was ever set) maps across; a clean install defaults to balanced
    // (24 MP on compatible rear cameras).
    static func migratedResolution(newRawValue: String?, legacyValue: Bool?) -> CameraResolution {
        if let newRawValue, let resolution = CameraResolution(rawValue: newRawValue) {
            return resolution
        }
        if let legacyValue {
            return legacyValue ? .maximum : .standard
        }
        return .balanced
    }
}
