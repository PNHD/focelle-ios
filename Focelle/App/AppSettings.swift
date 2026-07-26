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
    @Published var maximumResolution: Bool {
        didSet { defaults.set(maximumResolution, forKey: "maximumResolution") }
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
        maximumResolution = defaults.bool(forKey: "maximumResolution")
    }
}
