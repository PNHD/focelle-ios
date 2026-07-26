import Combine
import GoogleMobileAds
import UIKit

@MainActor
final class RewardedAdController: NSObject, ObservableObject, @MainActor FullScreenContentDelegate {
    @Published private(set) var isLoading = false
    private var ad: RewardedAd?
    private var completion: CheckedContinuation<String?, Never>?
    private var earnedReward = false

    func showTestAd() async -> String? {
        guard !isLoading else { return nil }
        isLoading = true
        MobileAds.shared.requestConfiguration.publisherPrivacyPersonalizationState = .disabled
        MobileAds.shared.requestConfiguration.setPublisherFirstPartyIDEnabled(false)
        MobileAds.shared.start()

        do {
            let loaded = try await RewardedAd.load(
                with: "ca-app-pub-3940256099942544/1712485313",
                request: Request()
            )
            loaded.fullScreenContentDelegate = self
            ad = loaded
            isLoading = false
            return await withCheckedContinuation { continuation in
                completion = continuation
                loaded.present(from: nil) { self.earnedReward = true }
            }
        } catch {
            isLoading = false
            return nil
        }
    }

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        finish(earnedReward ? UUID().uuidString.replacingOccurrences(of: "-", with: "") : nil)
    }

    func ad(
        _ ad: FullScreenPresentingAd,
        didFailToPresentFullScreenContentWithError error: any Error
    ) {
        finish(nil)
    }

    private func finish(_ rewardId: String?) {
        ad = nil
        earnedReward = false
        completion?.resume(returning: rewardId)
        completion = nil
    }
}
