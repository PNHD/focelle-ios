import SwiftUI

struct ReferralView: View {
    @EnvironmentObject private var referral: Referral
    @EnvironmentObject private var settings: AppSettings
    @State private var code = ""

    var body: some View {
        Form {
            if let snapshot = referral.snapshot {
                Section("referral.yourCode") {
                    Text(snapshot.code)
                        .font(.title2.monospaced().bold())
                        .textSelection(.enabled)
                    ShareLink(
                        item: String(
                            format: String(localized: "referral.shareText"),
                            snapshot.code
                        )
                    )
                }

                if !snapshot.claimed {
                    Section("referral.enterCode") {
                        TextField("referral.code", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button("referral.apply") {
                            Task {
                                await referral.redeem(code)
                                Analytics.record(
                                    "referral_outcome",
                                    enabled: settings.analyticsEnabled,
                                    category: referral.messageKey == "referral.claimed"
                                        ? "success"
                                        : "failed"
                                )
                            }
                        }
                        .disabled(code.count != 8)
                    }
                }

                Section {
                    Text("referral.detail")
                    if snapshot.qualified, let end = snapshot.benefitEndsAt {
                        LabeledContent("referral.proUntil") {
                            Text(end, style: .date)
                        }
                    }
                }
            } else {
                ProgressView()
            }

            if let messageKey = referral.messageKey {
                Text(LocalizedStringKey(messageKey)).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("referral.title")
        .task { await referral.refresh() }
    }
}
