import SwiftUI

enum ToolModule: String, CaseIterable, Identifiable {
    case personalFinance
    case myStocks
    case currencyExchange

    var id: Self { self }

    var title: String {
        switch self {
        case .personalFinance: return "个人金融"
        case .myStocks: return "我的股票"
        case .currencyExchange: return "换汇记录"
        }
    }

    var subtitle: String {
        switch self {
        case .personalFinance: return "银行账户与银行卡"
        case .myStocks: return "A 股与美股持仓"
        case .currencyExchange: return "记录汇率与换汇损耗"
        }
    }

    var systemImage: String {
        switch self {
        case .personalFinance: return "building.columns.fill"
        case .myStocks: return "chart.line.uptrend.xyaxis"
        case .currencyExchange: return "arrow.left.arrow.right.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .personalFinance: return .blue
        case .myStocks: return .green
        case .currencyExchange: return .indigo
        }
    }

    var visibilityKey: String { "tool-module-\(rawValue)-visible" }
}
