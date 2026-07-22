import Foundation

enum BankRegion: String, Codable, CaseIterable, Identifiable {
    case domestic
    case overseas

    var id: Self { self }

    var title: String {
        switch self {
        case .domestic: return "国内银行"
        case .overseas: return "境外银行"
        }
    }
}

enum ForeignAccountType: String, Codable, CaseIterable, Identifiable {
    case savings
    case current
    case fixedDeposit
    case foreignCurrency
    case securities
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .savings: return "储蓄账户"
        case .current: return "往来账户"
        case .fixedDeposit: return "定期存款账户"
        case .foreignCurrency: return "外汇账户"
        case .securities: return "证券账户"
        case .other: return "其他账户"
        }
    }
}

enum CardExpiryPrecision: String, Codable, CaseIterable, Identifiable {
    case yearMonth
    case fullDate

    var id: Self { self }

    var title: String {
        switch self {
        case .yearMonth: return "年月"
        case .fullDate: return "年月日"
        }
    }
}

enum CardStatus: String, Codable, CaseIterable, Identifiable {
    case normal
    case abnormal
    case closed

    var id: Self { self }

    var title: String {
        switch self {
        case .normal: return "正常"
        case .abnormal: return "异常"
        case .closed: return "已销户"
        }
    }
}

struct BankCard: Identifiable, Codable, Equatable {
    var id = UUID()
    var accountID: UUID? = nil
    var bankName = ""
    var branchName = ""
    var openedAt = Date()
    var cardNumber = ""
    var cvv = ""
    var expiryDate = Date()
    var expiryPrecision: CardExpiryPrecision = .yearMonth
    var cardType = "借记卡"
    var status: CardStatus = .normal
    var holderName = ""
    var applePay = false
    var defaultPayment = false
    var note = ""

    private enum CodingKeys: String, CodingKey {
        case id, accountID, bankName, branchName, openedAt, cardNumber, cvv
        case expiryDate, expiryPrecision, cardType, status, holderName, applePay, defaultPayment, note
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        accountID = try values.decodeIfPresent(UUID.self, forKey: .accountID)
        bankName = try values.decodeIfPresent(String.self, forKey: .bankName) ?? ""
        branchName = try values.decodeIfPresent(String.self, forKey: .branchName) ?? ""
        openedAt = try values.decodeIfPresent(Date.self, forKey: .openedAt) ?? Date()
        cardNumber = try values.decodeIfPresent(String.self, forKey: .cardNumber) ?? ""
        cvv = try values.decodeIfPresent(String.self, forKey: .cvv) ?? ""
        expiryDate = try values.decodeIfPresent(Date.self, forKey: .expiryDate) ?? Date()
        expiryPrecision = try values.decodeIfPresent(CardExpiryPrecision.self, forKey: .expiryPrecision) ?? .yearMonth
        cardType = try values.decodeIfPresent(String.self, forKey: .cardType) ?? "借记卡"
        status = try values.decodeIfPresent(CardStatus.self, forKey: .status) ?? .normal
        holderName = try values.decodeIfPresent(String.self, forKey: .holderName) ?? ""
        applePay = try values.decodeIfPresent(Bool.self, forKey: .applePay) ?? false
        defaultPayment = try values.decodeIfPresent(Bool.self, forKey: .defaultPayment) ?? false
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct BankAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var region: BankRegion = .domestic
    var foreignAccountTypes: Set<ForeignAccountType> = []
    var bankName = ""
    var branchName = ""
    var openedAt = Date()
    var name = ""
    var currency = ""
    var accountNumber = ""
    var swift = ""
    var iban = ""
    var status = "正常"
    var note = ""

    private enum CodingKeys: String, CodingKey {
        case id, region, foreignAccountTypes, bankName, branchName, openedAt, name, currency
        case accountNumber, swift, iban, status, note
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bankName = try values.decodeIfPresent(String.self, forKey: .bankName) ?? ""
        branchName = try values.decodeIfPresent(String.self, forKey: .branchName) ?? ""
        openedAt = try values.decodeIfPresent(Date.self, forKey: .openedAt) ?? Date()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        currency = try values.decodeIfPresent(String.self, forKey: .currency) ?? ""
        accountNumber = try values.decodeIfPresent(String.self, forKey: .accountNumber) ?? ""
        swift = try values.decodeIfPresent(String.self, forKey: .swift) ?? ""
        iban = try values.decodeIfPresent(String.self, forKey: .iban) ?? ""
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "正常"
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        foreignAccountTypes = try values.decodeIfPresent(Set<ForeignAccountType>.self, forKey: .foreignAccountTypes) ?? []

        if let savedRegion = try values.decodeIfPresent(BankRegion.self, forKey: .region) {
            region = savedRegion
        } else {
            region = accountNumber.isEmpty && swift.isEmpty && iban.isEmpty ? .domestic : .overseas
        }
    }

    var foreignAccountTypeSummary: String {
        ForeignAccountType.allCases
            .filter { foreignAccountTypes.contains($0) }
            .map(\.title)
            .joined(separator: "、")
    }
}

struct VaultData: Codable {
    var accounts: [BankAccount] = []
    var cards: [BankCard] = []
}
