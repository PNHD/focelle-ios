import SwiftUI

@main
struct FocelleApp: App {
    @StateObject private var presets = PresetStore()

    var body: some Scene {
        WindowGroup {
            CameraView()
                .environmentObject(presets)
                .task { await presets.sync() }
        }
    }
}
