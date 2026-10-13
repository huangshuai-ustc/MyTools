import Foundation

/// Runs against production domain models without loading any user Vault.
@main struct BrokerageRegressionCheck {
    static func main() throws {
        var institution = FinancialInstitution(kind: .brokerage)
        var first = BrokerageAccount()
        first.name = "Primary"
        first.accountNumber = "U100001"
        first.holderName = "Example"
        first.accountType = .margin
        first.openedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let second = BrokerageAccount()
        institution.brokerageAccounts = [first, second]
        var route = FinanceReceivingMethod()
        route.accountID = first.id
        route.details.fields = [FinanceReceivingField(kind: .reference)]
        institution.receivingMethods = [route]
        var login = FinanceLogin()
        login.accountIDs = [first.id, second.id]
        institution.logins = [login]
        try institution.validate()
        let original = institution
        institution.removeAccount(id: first.id)
        try institution.validate()
        precondition(institution.brokerageAccounts.map(\.id) == [second.id])
        precondition(institution.receivingMethods.map(\.id) == [route.id])
        precondition(institution.receivingMethods[0].accountID == nil)
        precondition(institution.logins[0].accountIDs == [second.id])
        institution.removeAccount(id: first.id)
        try institution.validate()
        institution.brokerageAccounts[0].fundingProfileIDs = [route.id]
        institution.removeReceivingMethod(id: route.id)
        precondition(institution.receivingMethods.isEmpty)
        precondition(institution.brokerageAccounts[0].fundingProfileIDs.isEmpty)
        try institution.validate()
        let restored = try JSONDecoder().decode(FinancialInstitution.self, from: JSONEncoder().encode(original))
        precondition(restored == original)
        print("PASS: brokerage account deletion, association cleanup, funding deletion, repeat deletion, and round trip")
    }
}
