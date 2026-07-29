import SwiftUI

enum ToolModule: String, CaseIterable, Identifiable {
    case personalFinance
    case myStocks
    case currencyExchange
    case healthRecords
    case secrets

    var id: Self { self }

    var title: String {
        switch self {
        case .personalFinance: return "金融账户"
        case .myStocks: return "股票投资"
        case .currencyExchange: return "换汇记录"
        case .healthRecords: return "健康档案"
        case .secrets: return "保密资料"
        }
    }

    var subtitle: String {
        switch self {
        case .personalFinance: return "银行账户与银行卡"
        case .myStocks: return "A 股、港股与美股投资"
        case .currencyExchange: return "记录汇率与换汇损耗"
        case .healthRecords: return "就诊、复诊、购药、体检"
        case .secrets: return "账号、Token、密钥与授权"
        }
    }

    var systemImage: String {
        switch self {
        case .personalFinance: return "building.columns.fill"
        case .myStocks: return "chart.line.uptrend.xyaxis"
        case .currencyExchange: return "arrow.left.arrow.right.circle.fill"
        case .healthRecords: return "cross.case.fill"
        case .secrets: return "lock.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .personalFinance: return .blue
        case .myStocks: return .green
        case .currencyExchange: return .indigo
        case .healthRecords: return .pink
        case .secrets: return .orange
        }
    }

    var visibilityKey: String { "tool-module-\(rawValue)-visible" }
}
