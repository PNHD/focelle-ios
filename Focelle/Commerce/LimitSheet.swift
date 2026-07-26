import SwiftUI

struct LimitSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var quota: Quota
    @StateObject private var ad = RewardedAdController()
    @State private var messageKey: LocalizedStringKey?
    let onPurchase: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "sparkles")
                    .font(.system(size: 42))
                    .foregroundStyle(.orange)
                Text("limit.title").font(.title2.bold())
                Text("limit.detail")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if quota.snapshot.adsRemaining > 0 {
                    Button {
                        watchAd()
                    } label: {
                        if ad.isLoading {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("limit.watchAd").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(ad.isLoading)
                }

                Button("limit.buy", action: onPurchase)
                    .buttonStyle(.bordered)

                if let messageKey {
                    Text(messageKey).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("limit.navigation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func watchAd() {
        Task {
            guard let rewardId = await ad.showTestAd() else {
                messageKey = "limit.adFailed"
                return
            }
            do {
                try await quota.grantTestReward(rewardId)
                messageKey = "limit.rewardGranted"
            } catch Quota.QuotaError.featureDisabled {
                messageKey = "limit.testDisabled"
            } catch {
                messageKey = "limit.rewardFailed"
            }
        }
    }
}
