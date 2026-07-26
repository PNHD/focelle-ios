import Combine
import Foundation
import StoreKit

@MainActor
final class Store: ObservableObject {
    static let subscriptionProductIDs = [
        "com.pnhd.focelle.pro.monthly",
        "com.pnhd.focelle.pro.yearly",
    ]
    static let creditPacks = [
        "com.pnhd.focelle.credits.30": 30,
        "com.pnhd.focelle.credits.100": 100,
    ]
    static let productIDs = subscriptionProductIDs + creditPacks.keys.sorted()

    struct Entitlement: Codable, Equatable {
        let productID: String
        let expirationDate: Date

        func isActive(at date: Date = .now) -> Bool {
            expirationDate > date
        }
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var entitlement: Entitlement?
    @Published private(set) var isLoading = false
    @Published var messageKey: String?

    private let defaults: UserDefaults
    private static let cacheKey = "storeEntitlement"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entitlement = defaults.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode(Entitlement.self, from: $0) }
        if entitlement?.isActive() != true { entitlement = nil }

        Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
    }

    var isPro: Bool { entitlement?.isActive() == true }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: Self.productIDs)
                .sorted {
                    (Self.productIDs.firstIndex(of: $0.id) ?? .max)
                        < (Self.productIDs.firstIndex(of: $1.id) ?? .max)
                }
            await refreshEntitlement()
        } catch {
            messageKey = "purchase.error.load"
        }
    }

    func purchase(_ product: Product) async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            switch try await product.purchase() {
            case let .success(result):
                let delivered = await handle(result)
                messageKey = delivered
                    ? (Self.creditPacks[product.id] == nil
                        ? "purchase.success"
                        : "account.creditsPurchased")
                    : "purchase.error.verify"
                return delivered
            case .pending:
                messageKey = "purchase.pending"
            case .userCancelled:
                break
            @unknown default:
                messageKey = "purchase.error.purchase"
            }
        } catch {
            messageKey = "purchase.error.purchase"
        }
        return false
    }

    func restore() async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            messageKey = isPro ? "purchase.restored" : "purchase.noneToRestore"
            return isPro
        } catch {
            messageKey = "purchase.error.restore"
            return false
        }
    }

    private func refreshEntitlement() async {
        var current: Entitlement?
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  Self.subscriptionProductIDs.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  let expiration = transaction.expirationDate,
                  expiration > .now
            else { continue }
            if current.map({ expiration > $0.expirationDate }) ?? true {
                current = Entitlement(productID: transaction.productID, expirationDate: expiration)
            }
            await submit(result.jwsRepresentation)
        }
        entitlement = current
        cache()
    }

    @discardableResult
    private func handle(_ result: VerificationResult<Transaction>) async -> Bool {
        guard case let .verified(transaction) = result,
              Self.productIDs.contains(transaction.productID)
        else {
            messageKey = "purchase.error.verify"
            return false
        }
        if Self.subscriptionProductIDs.contains(transaction.productID),
           transaction.revocationDate == nil,
           let expiration = transaction.expirationDate,
           expiration > .now {
            entitlement = Entitlement(productID: transaction.productID, expirationDate: expiration)
            cache()
        } else if Self.subscriptionProductIDs.contains(transaction.productID) {
            await refreshEntitlement()
        }
        if transaction.environment != .xcode {
            guard await submit(result.jwsRepresentation) else { return false }
        }
        await transaction.finish()
        return true
    }

    private func submit(_ signedTransaction: String) async -> Bool {
        do {
            var request = try await FocelleAPI.request(path: "v1/store/transaction", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let session = AccountSession.load() {
                request.setValue(session, forHTTPHeaderField: "X-Focelle-Session")
            }
            request.httpBody = try JSONEncoder().encode(
                StoreTransactionRequest(
                    deviceId: await FocelleAPI.deviceID(),
                    signedTransaction: signedTransaction
                )
            )
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 202
        } catch {
            return false
        }
    }

    private func cache() {
        if let entitlement, let data = try? JSONEncoder().encode(entitlement) {
            defaults.set(data, forKey: Self.cacheKey)
        } else {
            defaults.removeObject(forKey: Self.cacheKey)
        }
    }
}

private struct StoreTransactionRequest: Encodable {
    let deviceId: String
    let signedTransaction: String
}
