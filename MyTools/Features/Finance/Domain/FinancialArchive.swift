#if MYTOOLS_FEATURE_FINANCE
  import Foundation

  enum FinanceService: String, Codable, CaseIterable, Identifiable {
    case banking, securities, payments, other
    var id: Self { self }
    var title: String {
      switch self {
      case .banking: "银行"
      case .securities: "证券"
      case .payments: "支付"
      case .other: "其他"
      }
    }
    var symbol: String {
      switch self {
      case .banking: "building.columns"
      case .securities: "chart.line.uptrend.xyaxis"
      case .payments: "globe"
      case .other: "folder"
      }
    }
  }

  enum FinanceAccountKind: String, Codable, CaseIterable, Identifiable {
    case savings, current, checking, integrated, termDeposit, securities, investment,
      foreignExchange, credit, payment, pension, socialSecurity, providentFund, other
    var id: Self { self }
    var title: String {
      switch self {
      case .savings: "储蓄账户"
      case .current: "往来账户"
      case .checking: "支票账户"
      case .integrated: "综合账户"
      case .termDeposit: "定期账户"
      case .securities: "证券账户"
      case .investment: "投资账户"
      case .foreignExchange: "外汇账户"
      case .credit: "信用账户"
      case .payment: "支付／多币种账户"
      case .pension: "个人养老金账户"
      case .socialSecurity: "社保账户"
      case .providentFund: "公积金账户"
      case .other: "其他账户"
      }
    }
  }

  struct FinancialAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var kind: FinanceAccountKind = .savings
    var customType = ""
    var accountNumber = ""
    var holderName = ""
    var currencies: Set<CurrencyCode> = []
    var country = ""
    var legalEntity = ""
    var branchName = ""
    var branchLocation: BankBranchLocation?
    var openedAt: Date?
    var status: AccountStatus = .normal
    var note = ""
    var bankRegion: BankRegion?
    var subaccounts: [FinancialAccount] = []
    var brokerage: BrokerageAccountDetails?
    /// Wise keeps exactly one receiving profile together with each currency account.
    var receivingProfile: FinanceReceivingMethod?

    var typeTitle: String { kind == .other && !customType.isEmpty ? customType : kind.title }
    var displayName: String { name.isEmpty ? typeTitle : name }
    var maskedAccountNumber: String {
      AccountNumberFormatter.masked(accountNumber)
    }
    var currencySummary: String {
      CurrencyCode.displayOrdered(currencies).map(\.rawValue).joined(separator: " · ")
    }
  }

  enum FinanceReceivingFieldKind: String, Codable, CaseIterable, Identifiable {
    case beneficiary, beneficiaryAddress, bankName, bankAddress, bankNameAndAddress, bankAccountNumber, iban, bic
    case aba, sortCode, bsb, bankCode, branchCode, institutionNumber, accountType, intermediaryBank
    case ultimateBeneficiary, ultimateAccountNumber, reference, instructions, custom
    var id: Self { self }
    var title: String {
      switch self {
      case .beneficiary: "收款人名称"
      case .beneficiaryAddress: "收款人地址"
      case .bankName: "收款银行"
      case .bankAddress: "收款银行地址"
      case .bankNameAndAddress: "银行名称和地址"
      case .bankAccountNumber: "收款银行账号"
      case .iban: "IBAN"
      case .bic: "SWIFT / BIC"
      case .aba: "ABA / Routing Number"
      case .sortCode: "Sort Code"
      case .bsb: "BSB"
      case .bankCode: "银行代码"
      case .branchCode: "分行代码"
      case .institutionNumber: "机构号码"
      case .accountType: "账户类型"
      case .intermediaryBank: "中间行资料"
      case .ultimateBeneficiary: "最终入账人 / For Further Credit"
      case .ultimateAccountNumber: "最终入账账户号"
      case .reference: "必填附言 / Reference"
      case .instructions: "办理步骤与说明"
      case .custom: "自定义字段"
      }
    }
  }

  struct FinanceReceivingField: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: FinanceReceivingFieldKind = .custom
    var customName = ""
    var value = ""
    var title: String { kind == .custom && !customName.isEmpty ? customName : kind.title }
  }

  struct FinanceReceivingDetails: Codable, Equatable {
    var name = ""
    var currency: CurrencyCode?
    /// Nil preserves pre-multi-currency records; a non-nil empty set means unspecified.
    var currencies: Set<CurrencyCode>?
    var fields: [FinanceReceivingField] = []
    var note = ""

    var effectiveCurrencies: Set<CurrencyCode> { currencies ?? Set([currency].compactMap { $0 }) }
    var currencySummary: String {
      CurrencyCode.displayOrdered(effectiveCurrencies).map(\.rawValue).joined(separator: " · ")
    }
    var displayName: String {
      name.isEmpty ? (currencySummary.isEmpty ? "收款资料" : "\(currencySummary) 收款资料") : name
    }
    var shareText: String {
      ([displayName, currencySummary.isEmpty ? "" : "币种：\(currencySummary)"]
        + fields.filter { !$0.value.isEmpty }.map { "\($0.title)：\($0.value)" } + [note])
        .filter { !$0.isEmpty }.joined(separator: "\n")
    }
  }

  struct FinanceReceivingMethod: Identifiable, Codable, Equatable {
    var id = UUID()
    var accountID: UUID?
    var details = FinanceReceivingDetails()
  }

  struct FinanceLogin: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "登录信息"
    /// Empty means institution-wide; one credential can serve multiple accounts.
    var accountIDs: Set<UUID> = []
    var fields: [AdditionalLoginField] = []
    init(id: UUID = UUID(), name: String = "登录信息", accountIDs: Set<UUID> = [], fields: [AdditionalLoginField] = []) {
      self.id = id; self.name = name; self.accountIDs = accountIDs; self.fields = fields
    }
  }

  struct FinanceDocument: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = ""
    var accountID: UUID?
    var receivingMethodID: UUID?
    var attachment: FileAttachment
  }

  enum FinancialArchiveError: LocalizedError {
    case unsupportedVersion, invalidRelationships, wrongCategory, editConflict
    var errorDescription: String? {
      switch self {
      case .unsupportedVersion: "金融档案来自更新版本，请升级应用后再读取。"
      case .invalidRelationships: "金融档案包含重复标识或无效关联，已停止保存。"
      case .wrongCategory: "机构类型与专属资料不一致，不能保存。"
      case .editConflict: "编辑期间资料已变化，请重新打开编辑。"
      }
    }
  }


#endif
