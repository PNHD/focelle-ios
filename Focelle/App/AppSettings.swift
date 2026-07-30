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
        didSet { defaults.set(requestedResolution.rawValue, forKey: "requestedResolution") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onDeviceOnly = defaults.bool(forKey: "onDeviceOnly")
        analyticsEnabled = defaults.object(forKey: "analyticsEnabled") as? Bool ?? true
        guidanceEnabled = defaults.object(forKey: "guidanceEnabled") as? Bool ?? true
        voiceGuidance = defaults.bool(forKey: "voiceGuidance")
        autoCapture = defaults.bool(forKey: "autoCapture")
        saveOriginal = defaults.bool(forKey: "saveOriginal")
        saveLocation = defaults.bool(forKey: "saveLocation")
        requestedResolution =
            defaults.string(forKey: "requestedResolution").flatMap(CameraResolution.init(rawValue:))
            ?? .standard
    }
}
