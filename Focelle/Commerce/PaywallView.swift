import AuthenticationServices
import StoreKit
import SwiftUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var account: Account
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("purchase.title").font(.title2.bold())
                Text("purchase.detail")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                ForEach(
                    store.products.filter {
                        Store.subscriptionProductIDs.contains($0.id)
                    }, id: \.id
                ) { product in
                    productButton(product)
                }

                if !store.products.filter({ Store.creditPacks[$0.id] != nil }).isEmpty {
                    Divider()
                    Text("account.creditPacks").font(.headline)
                    if account.isSignedIn {
                        ForEach(
                            store.products.filter {
                                Store.creditPacks[$0.id] != nil
                            }, id: \.id
                        ) { product in
                            productButton(product)
                        }
                        LabeledContent("account.aiCredits", value: "\(account.credits)")
                    } else {
                        SignInWithAppleButton(
                            .continue,
                            onRequest: account.configure,
                            onCompletion: account.complete
                        )
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 48)
                        Text("account.signInForCredits")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if store.products.isEmpty, store.isLoading {
                    ProgressView()
                }

                Button("purchase.restore") {
                    Task {
                        let restored = await store.restore()
                        Analytics.record(
                            "restore",
                            enabled: settings.analyticsEnabled,
                            category: restored ? "success" : "failed"
                        )
                    }
                }
                .disabled(store.isLoading)

                if let messageKey = store.messageKey {
                    Text(LocalizedStringKey(messageKey))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("purchase.navigation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") { dismiss() }
                }
            }
            .task { await store.refresh() }
            .task { await account.refresh() }
        }
    }

    private func productButton(_ product: Product) -> some View {
        Button {
            Task {
                let purchased = await store.purchase(product)
                Analytics.record(
                    "purchase",
                    enabled: settings.analyticsEnabled,
                    category: purchased ? "success" : "failed"
                )
                if purchased {
                    await account.refresh()
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(product.displayName).font(.headline)
                    Text(product.description).font(.caption)
                }
                Spacer()
                Text(product.displayPrice).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(store.isLoading)
    }
}
