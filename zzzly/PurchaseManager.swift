import Foundation
import Observation
import StoreKit

@Observable
@MainActor
final class PurchaseManager {
    private let productIDs = ["zzzly.deep_report"]

    var product: Product?
    var isUnlocked = false
    var purchaseError: String?

    func loadProducts() async {
        do {
            product = try await Product.products(for: productIDs).first
            await refreshEntitlements()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func buyDeepReport() async {
        guard let product else {
            purchaseError = "Product is not configured yet."
            return
        }

        do {
            let result = try await product.purchase()
            if case let .success(verification) = result, case .verified(let transaction) = verification {
                isUnlocked = true
                await transaction.finish()
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               productIDs.contains(transaction.productID) {
                isUnlocked = true
                return
            }
        }
    }
}
