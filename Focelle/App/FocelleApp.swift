import SwiftUI

@main
struct FocelleApp: App {
    @StateObject private var presets = PresetStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var location = LocationProvider()
    @StateObject private var beta = BetaAccess()
    @StateObject private var quota = Quota()
    @StateObject private var store = Store()
    @StateObject private var account = Account()
    @StateObject private var referral = Referral()

    var body: some Scene {
        WindowGroup {
            CameraView()
                .environmentObject(presets)
                .environmentObject(settings)
                .environmentObject(location)
                .environmentObject(beta)
                .environmentObject(quota)
                .environmentObject(store)
                .environmentObject(account)
                .environmentObject(referral)
                .task { await presets.sync() }
                .task { await beta.refresh() }
                .task { await quota.refresh() }
                .task { await store.refresh() }
                .task { await account.refresh() }
                .task { await referral.refresh() }
        }
    }
}
