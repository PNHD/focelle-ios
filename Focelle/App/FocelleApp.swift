import SwiftUI

@main
struct FocelleApp: App {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
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
            Group {
                if onboardingComplete {
                    CameraView()
                } else {
                    OnboardingView {
                        onboardingComplete = true
                        Analytics.record(
                            "onboarding_complete",
                            enabled: settings.analyticsEnabled
                        )
                    }
                }
            }
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
                .task { await account.refresh() }
                .task { await referral.refresh() }
                .onAppear {
                    Analytics.recordReturnMilestones(enabled: settings.analyticsEnabled)
                }
        }
    }
}

private struct OnboardingView: View {
    let continueAction: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "viewfinder")
                .font(.system(size: 68, weight: .light))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("onboarding.title")
                    .font(.largeTitle.bold())
                Text("onboarding.subtitle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 20) {
                row("iphone", "onboarding.onDevice")
                row("cloud", "onboarding.cloud")
                row("lock.shield", "onboarding.control")
            }
            .frame(maxWidth: 420)

            Spacer()
            Button("onboarding.continue", action: continueAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.orange)
            Text("onboarding.permission")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
    }

    private func row(_ icon: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.orange)
                .frame(width: 28)
        }
    }
}
