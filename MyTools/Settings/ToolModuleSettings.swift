import Foundation
import Combine

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
