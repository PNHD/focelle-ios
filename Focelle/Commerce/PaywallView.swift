import StoreKit
import SwiftUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: Store

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

                ForEach(store.products, id: \.id) { product in
                    Button {
                        Task { await store.purchase(product) }
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

                if store.products.isEmpty, store.isLoading {
                    ProgressView()
                }

                Button("purchase.restore") {
                    Task { await store.restore() }
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
        }
    }
}
