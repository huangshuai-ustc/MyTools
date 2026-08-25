import SwiftUI

struct HomeFeatureSettingsView: View {
    @EnvironmentObject private var moduleSettings: ToolModuleSettings

    var body: some View {
        List {
            Section("首页功能") {
                ForEach(moduleSettings.orderedModules) { module in
                    Toggle(isOn: visibilityBinding(for: module)) {
                        moduleLabel(module)
                    }
                }
                .onMove(perform: moduleSettings.moveModules)
            }

        }
        .appNavigationTitle("首页功能")
        .iOSLabeledBackButton("设置")
#if os(iOS)
        .toolbar { EditButton() }
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
    }

    private func moduleLabel(_ module: ToolModule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: module.systemImage)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    moduleSettings.isVisible(module) ? module.tint : Color.gray,
                    in: RoundedRectangle(cornerRadius: 7)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title)
                    .foregroundStyle(moduleSettings.isVisible(module) ? .primary : .secondary)
                Text(module.subtitle)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func visibilityBinding(for module: ToolModule) -> Binding<Bool> {
        Binding(
            get: { moduleSettings.isVisible(module) },
            set: { moduleSettings.setVisible($0, for: module) }
        )
    }

}
