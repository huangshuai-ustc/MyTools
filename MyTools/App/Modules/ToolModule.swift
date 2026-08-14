import SwiftUI

enum ToolModule: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case personalFinance
    case myStocks
    case currencyExchange
    case healthRecords
    case foodMap
    case secrets
    case documents
    case bills
    case sportsLottery

    var id: Self { self }

    var title: String {
        switch self {
        case .personalFinance: return "金融账户"
        case .myStocks: return "股票投资"
        case .currencyExchange: return "换汇记录"
        case .healthRecords: return "健康档案"
        case .foodMap: return "美食地图"
        case .secrets: return "保密资料"
        case .documents: return "证照资料"
        case .bills: return "收支账单"
        case .sportsLottery: return "体彩开奖"
        }
    }

    var subtitle: String {
        switch self {
        case .personalFinance: return "银行账户与银行卡"
        case .myStocks: return "A 股、港股与美股投资"
        case .currencyExchange: return "记录汇率与换汇损耗"
        case .healthRecords: return "就诊、复诊、购药、体检"
        case .foodMap: return "记录吃过与想吃的美食"
        case .secrets: return "账号、Token、密钥与授权"
        case .documents: return "证件、证书与重要文书"
        case .bills: return "记录、识别与导入付款明细"
        case .sportsLottery: return "按赛事查看比赛开奖结果"
        }
    }

    var systemImage: String {
        switch self {
        case .personalFinance: return "building.columns.fill"
        case .myStocks: return "chart.line.uptrend.xyaxis"
        case .currencyExchange: return "arrow.left.arrow.right.circle.fill"
        case .healthRecords: return "cross.case.fill"
        case .foodMap: return "fork.knife.circle.fill"
        case .secrets: return "lock.shield.fill"
        case .documents: return "person.text.rectangle.fill"
        case .bills: return "receipt.fill"
        case .sportsLottery: return "soccerball"
        }
    }

    var tint: Color {
        switch self {
        case .personalFinance: return .blue
        case .myStocks: return .green
        case .currencyExchange: return .indigo
        case .healthRecords: return .pink
        case .foodMap: return .red
        case .secrets: return .orange
        case .documents: return .teal
        case .bills: return .cyan
        case .sportsLottery: return .purple
        }
    }

    var visibilityKey: String { "tool-module-\(rawValue)-visible" }

    var defaultIsVisible: Bool {
        switch self {
        case .personalFinance:
#if MYTOOLS_DEFAULT_HIDDEN_FINANCE
            return false
#else
            return true
#endif
        case .myStocks:
#if MYTOOLS_DEFAULT_HIDDEN_STOCKS
            return false
#else
            return true
#endif
        case .currencyExchange:
#if MYTOOLS_DEFAULT_HIDDEN_CURRENCY_EXCHANGE
            return false
#else
            return true
#endif
        case .healthRecords:
#if MYTOOLS_DEFAULT_HIDDEN_HEALTH
            return false
#else
            return true
#endif
        case .foodMap:
#if MYTOOLS_DEFAULT_HIDDEN_FOOD_MAP
            return false
#else
            return true
#endif
        case .secrets:
#if MYTOOLS_DEFAULT_HIDDEN_SECRETS
            return false
#else
            return true
#endif
        case .documents:
#if MYTOOLS_DEFAULT_HIDDEN_DOCUMENTS
            return false
#else
            return true
#endif
        case .bills:
#if MYTOOLS_DEFAULT_HIDDEN_BILLS
            return false
#else
            return true
#endif
        case .sportsLottery:
#if MYTOOLS_DEFAULT_HIDDEN_SPORTS_LOTTERY
            return false
#else
            return true
#endif
        }
    }

    var hasSettings: Bool {
        switch self {
        case .myStocks:
            return true
        case .personalFinance, .currencyExchange, .healthRecords, .foodMap, .secrets, .documents, .sportsLottery:
            return false
        case .bills:
            return true
        }
    }

    var definition: ToolModuleDefinition {
        ToolModuleCatalog.definition(for: self)
    }
}

enum ToolModuleCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case localVault
    case attachments
    case exchangeRates
    case stockQuotes
    case stockCharts
    case notifications
}

struct ToolModuleDefinition: Sendable, Equatable {
    let module: ToolModule
    let capabilities: Set<ToolModuleCapability>
    let participatesInBackup: Bool
    let participatesInCloudSync: Bool

    var ownsAttachments: Bool {
        capabilities.contains(.attachments)
    }
}

enum ToolModuleCatalog {
    static let definitions: [ToolModuleDefinition] = [
        ToolModuleDefinition(
            module: .personalFinance,
            capabilities: [.localVault, .attachments],
            participatesInBackup: true,
            participatesInCloudSync: true
        ),
        ToolModuleDefinition(
            module: .myStocks,
            capabilities: [.localVault, .exchangeRates, .stockQuotes, .stockCharts, .notifications],
            participatesInBackup: true,
            participatesInCloudSync: true
        ),
        ToolModuleDefinition(
            module: .currencyExchange,
            capabilities: [.localVault, .exchangeRates, .notifications],
            participatesInBackup: true,
            participatesInCloudSync: true
        ),
        ToolModuleDefinition(
            module: .healthRecords,
            capabilities: [.localVault, .attachments],
            participatesInBackup: true,
            participatesInCloudSync: true
        ),
        ToolModuleDefinition(
            module: .foodMap,
            capabilities: [.localVault, .attachments],
            participatesInBackup: true,
            participatesInCloudSync: true
        ),
        ToolModuleDefinition(
            module: .secrets,
            capabilities: [.localVault, .attachments],
            participatesInBackup: true,
            participatesInCloudSync: true
        ),
        ToolModuleDefinition(
            module: .documents,
            capabilities: [.localVault, .attachments, .notifications],
            participatesInBackup: true,
            participatesInCloudSync: true
        ),
        ToolModuleDefinition(
            module: .bills,
            capabilities: [.localVault],
            participatesInBackup: true,
            participatesInCloudSync: true
        ),
        ToolModuleDefinition(
            module: .sportsLottery,
            capabilities: [],
            participatesInBackup: false,
            participatesInCloudSync: false
        )
    ]

    private static let definitionsByModule = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.module, $0) }
    )

    static func definition(for module: ToolModule) -> ToolModuleDefinition {
        guard let definition = definitionsByModule[module] else {
            preconditionFailure("Missing module definition for \(module.rawValue)")
        }
        return definition
    }

    static var allModules: Set<ToolModule> {
        CompiledToolModules.set
    }

    static var backupModules: Set<ToolModule> {
        Set(definitions.filter(\.participatesInBackup).map(\.module))
            .intersection(CompiledToolModules.set)
    }

    static var cloudSyncModules: Set<ToolModule> {
        Set(definitions.filter(\.participatesInCloudSync).map(\.module))
            .intersection(CompiledToolModules.set)
    }
}

enum CompiledToolModules {
    static let ordered: [ToolModule] = {
        var modules: [ToolModule] = []
#if MYTOOLS_FEATURE_FINANCE
        modules.append(.personalFinance)
#endif
#if MYTOOLS_FEATURE_STOCKS
        modules.append(.myStocks)
#endif
#if MYTOOLS_FEATURE_CURRENCY_EXCHANGE
        modules.append(.currencyExchange)
#endif
#if MYTOOLS_FEATURE_HEALTH
        modules.append(.healthRecords)
#endif
#if MYTOOLS_FEATURE_FOOD_MAP
        modules.append(.foodMap)
#endif
#if MYTOOLS_FEATURE_SECRETS
        modules.append(.secrets)
#endif
#if MYTOOLS_FEATURE_DOCUMENTS
        modules.append(.documents)
#endif
#if MYTOOLS_FEATURE_BILLS
        modules.append(.bills)
#endif
#if MYTOOLS_FEATURE_SPORTS_LOTTERY
        modules.append(.sportsLottery)
#endif
        return modules
    }()

    static let set = Set(ordered)

    static func contains(_ module: ToolModule) -> Bool {
        set.contains(module)
    }

    static func available(from requestedModules: Set<ToolModule>) -> Set<ToolModule> {
        requestedModules.intersection(set)
    }
}
