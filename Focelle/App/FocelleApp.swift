import SwiftUI

@main
struct FocelleApp: App {
    @StateObject private var presets = PresetStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var location = LocationProvider()
    @StateObject private var beta = BetaAccess()
    @StateObject private var quota = Quota()
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            CameraView()
                .environmentObject(presets)
                .environmentObject(settings)
                .environmentObject(location)
                .environmentObject(beta)
                .environmentObject(quota)
                .environmentObject(store)
                .task { await presets.sync() }
                .task { await beta.refresh() }
                .task { await quota.refresh() }
                .task { await store.refresh() }
        }
    }
}
