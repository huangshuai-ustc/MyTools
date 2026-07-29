import Foundation
import Combine
import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "白天模式"
        case .dark: return "夜间模式"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppFontSize: String, CaseIterable, Identifiable {
    case system
    case xSmall
    case small
    case medium
    case large
    case xLarge
    case xxLarge
    case xxxLarge
    case accessibility1
    case accessibility2
    case accessibility3
    case accessibility4
    case accessibility5

    var id: Self { self }

    static let adjustable: [Self] = [
        .xSmall,
        .small,
        .medium,
        .large,
        .xLarge,
        .xxLarge,
        .xxxLarge,
        .accessibility1,
        .accessibility2,
        .accessibility3,
        .accessibility4,
        .accessibility5
    ]

    var dynamicTypeSize: DynamicTypeSize? {
        switch self {
        case .system: return nil
        case .xSmall: return .xSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .xLarge
        case .xxLarge: return .xxLarge
        case .xxxLarge: return .xxxLarge
        case .accessibility1: return .accessibility1
        case .accessibility2: return .accessibility2
        case .accessibility3: return .accessibility3
        case .accessibility4: return .accessibility4
        case .accessibility5: return .accessibility5
        }
    }

    var sliderIndex: Int? {
        Self.adjustable.firstIndex(of: self)
    }
}

@MainActor
final class ToolModuleSettings: ObservableObject {
    private static let orderKey = "tool-module-order-v1"

    @Published private var visibility: [String: Bool] = [:]
    @Published private(set) var orderedModules: [ToolModule]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedOrder = defaults.stringArray(forKey: Self.orderKey) ?? []
        let savedModules = savedOrder.compactMap(ToolModule.init(rawValue:)).reduce(into: [ToolModule]()) { result, module in
            if !result.contains(module) { result.append(module) }
        }
        orderedModules = savedModules + ToolModule.allCases.filter { !savedModules.contains($0) }
        for module in ToolModule.allCases where defaults.object(forKey: module.visibilityKey) != nil {
            visibility[module.rawValue] = defaults.bool(forKey: module.visibilityKey)
        }
    }

    func isVisible(_ module: ToolModule) -> Bool { visibility[module.rawValue] ?? true }

    func setVisible(_ isVisible: Bool, for module: ToolModule) {
        visibility[module.rawValue] = isVisible
        defaults.set(isVisible, forKey: module.visibilityKey)
    }

    func moveModules(from source: IndexSet, to destination: Int) {
        orderedModules.move(fromOffsets: source, toOffset: destination)
        defaults.set(orderedModules.map(\.rawValue), forKey: Self.orderKey)
    }
}
