import SwiftUI

@main
struct FocelleApp: App {
    @StateObject private var presets = PresetStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var location = LocationProvider()

    var body: some Scene {
        WindowGroup {
            CameraView()
                .environmentObject(presets)
                .environmentObject(settings)
                .environmentObject(location)
                .task { await presets.sync() }
        }
    }
}
