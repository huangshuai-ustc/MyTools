import SwiftUI

struct ToolboxView: View {
    @EnvironmentObject private var moduleSettings: ToolModuleSettings

    private var visibleModules: [ToolModule] {
        moduleSettings.orderedModules.filter(moduleSettings.isVisible)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleModules) { module in
                    NavigationLink {
                        ToolModuleDestination(module: module)
                    } label: {
                        moduleRow(module)
                    }
                    .appListRowStyle()
                }
            }
            .overlay {
                if visibleModules.isEmpty {
                    ContentUnavailableView("暂无已启用功能", systemImage: "square.grid.2x2")
                }
            }
            .appNavigationTitle("工具")
#if os(iOS)
            .appAdaptiveLargeNavigationTitle()
            .listStyle(.insetGrouped)
#endif
        }
    }

    private func moduleRow(_ module: ToolModule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: module.systemImage)
                .appFont(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(module.tint, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
                Text(module.title).appFont(.headline)
                Text(module.subtitle).appFont(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
