import Foundation
import StoreKit

@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()
    
    static let premiumVoicesProductID = "com.kriyak.smoothtalker.premiumvoices"
    
    @Published private(set) var hasPremiumVoices = false {
        didSet {
            Preferences.shared.hasPremiumVoices = hasPremiumVoices
        }
    }
    @Published private(set) var premiumVoicesProduct: Product?
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage: String?
    
    private var transactionUpdatesTask: Task<Void, Never>?
    private var hasStarted = false
    
    private init() {
        Preferences.shared.hasPremiumVoices = false
    }
    
    deinit {
        transactionUpdatesTask?.cancel()
    }
    
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(transactionResult: result)
            }
        }
        
        await refresh()
    }
    
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        
        await refreshEntitlements()
        _ = try? await loadPremiumVoicesProduct()
    }
    
    func purchasePremiumVoices() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let product = try await premiumProduct()
            let result = try await product.purchase()
            
            switch result {
            case .success(let verificationResult):
                let transaction = try checkVerified(verificationResult)
                await refreshEntitlements()
                await transaction.finish()
                statusMessage = hasPremiumVoices ? "Premium voices unlocked." : "Purchase completed, but access is still pending."
            case .userCancelled:
                statusMessage = nil
            case .pending:
                statusMessage = "Purchase is pending approval."
            @unknown default:
                statusMessage = "Purchase could not be completed."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
    
    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            statusMessage = hasPremiumVoices ? "Purchases restored." : "No premium voice purchase was found."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
    
    func clearStatusMessage() {
        statusMessage = nil
    }
    
    private func handle(transactionResult: VerificationResult<Transaction>) async {
        guard let transaction = try? checkVerified(transactionResult),
              transaction.productID == Self.premiumVoicesProductID else {
            return
        }
        
        await refreshEntitlements()
        await transaction.finish()
    }
    
    @discardableResult
    private func loadPremiumVoicesProduct() async throws -> Product {
        let products = try await Product.products(for: [Self.premiumVoicesProductID])
        guard let product = products.first else {
            throw PurchaseError.productUnavailable
        }
        
        premiumVoicesProduct = product
        return product
    }
    
    private func premiumProduct() async throws -> Product {
        if let premiumVoicesProduct {
            return premiumVoicesProduct
        }
        
        return try await loadPremiumVoicesProduct()
    }
    
    private func refreshEntitlements() async {
        var isUnlocked = false
        
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result),
                  transaction.productID == Self.premiumVoicesProductID,
                  transaction.revocationDate == nil else {
                continue
            }
            
            isUnlocked = true
            break
        }
        
        hasPremiumVoices = isUnlocked
    }
    
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let verified):
            return verified
        case .unverified:
            throw PurchaseError.failedVerification
        }
    }
}

private enum PurchaseError: LocalizedError {
    case failedVerification
    case productUnavailable
    
    var errorDescription: String? {
        switch self {
        case .failedVerification:
            return "The App Store could not verify this purchase."
        case .productUnavailable:
            return "Premium voices are not available yet."
        }
    }
}
