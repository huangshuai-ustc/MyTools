import Foundation
import Combine
import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Codable, Identifiable, Sendable {
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

enum AppFontSize: String, CaseIterable, Codable, Identifiable, Sendable {
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
    @Published private(set) var visibilityRevision = 0
    private let defaults: UserDefaults
    private var visibilityChangeHandler: (@MainActor (ToolModule, Bool) -> Void)?
    private var preferenceChangeHandler: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedOrder = defaults.stringArray(forKey: Self.orderKey) ?? []
        let savedModules = savedOrder.compactMap(ToolModule.init(rawValue:)).reduce(into: [ToolModule]()) { result, module in
            if CompiledToolModules.contains(module), !result.contains(module) {
                result.append(module)
            }
        }
        orderedModules = savedModules + CompiledToolModules.ordered.filter { !savedModules.contains($0) }
        for module in CompiledToolModules.ordered where defaults.object(forKey: module.visibilityKey) != nil {
            visibility[module.rawValue] = defaults.bool(forKey: module.visibilityKey)
        }
    }

    func isVisible(_ module: ToolModule) -> Bool {
        CompiledToolModules.contains(module) && (visibility[module.rawValue] ?? true)
    }

    func setVisibilityChangeHandler(_ handler: (@MainActor (ToolModule, Bool) -> Void)?) {
        visibilityChangeHandler = handler
    }

    func setPreferenceChangeHandler(_ handler: (@MainActor () -> Void)?) {
        preferenceChangeHandler = handler
    }

    func setVisible(_ isVisible: Bool, for module: ToolModule) {
        guard CompiledToolModules.contains(module) else { return }
        guard isVisible != self.isVisible(module) else { return }
        visibility[module.rawValue] = isVisible
        defaults.set(isVisible, forKey: module.visibilityKey)
        visibilityRevision &+= 1
        visibilityChangeHandler?(module, isVisible)
        preferenceChangeHandler?()
    }

    func moveModules(from source: IndexSet, to destination: Int) {
        orderedModules.move(fromOffsets: source, toOffset: destination)
        defaults.set(orderedModules.map(\.rawValue), forKey: Self.orderKey)
        preferenceChangeHandler?()
    }

    var syncedModuleOrder: [ToolModule] {
        orderedModules
    }

    var syncedModuleVisibility: [String: Bool] {
        Dictionary(uniqueKeysWithValues: CompiledToolModules.ordered.map {
            ($0.rawValue, isVisible($0))
        })
    }

    func applySyncedPreferences(
        order: [ToolModule],
        visibility incomingVisibility: [String: Bool]
    ) {
        let uniqueOrder = order.reduce(into: [ToolModule]()) { result, module in
            if !result.contains(module) {
                result.append(module)
            }
        }
        let compiledOrder = uniqueOrder.filter(CompiledToolModules.contains)
        let normalizedOrder = compiledOrder + CompiledToolModules.ordered.filter {
            !compiledOrder.contains($0)
        }
        if orderedModules != normalizedOrder {
            orderedModules = normalizedOrder
            defaults.set(normalizedOrder.map(\.rawValue), forKey: Self.orderKey)
        }

        var changedVisibility: [(ToolModule, Bool)] = []
        for module in CompiledToolModules.ordered {
            guard let incoming = incomingVisibility[module.rawValue],
                  incoming != isVisible(module) else { continue }
            visibility[module.rawValue] = incoming
            defaults.set(incoming, forKey: module.visibilityKey)
            changedVisibility.append((module, incoming))
        }
        guard !changedVisibility.isEmpty else { return }
        visibilityRevision &+= 1
        for (module, isVisible) in changedVisibility {
            visibilityChangeHandler?(module, isVisible)
        }
    }
}
