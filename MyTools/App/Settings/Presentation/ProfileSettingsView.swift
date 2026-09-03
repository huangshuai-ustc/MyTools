import SwiftUI

struct ProfileSettingsView: View {
    @EnvironmentObject private var moduleSettings: ToolModuleSettings

    private var orderedModuleSettings: [ToolModule] {
        moduleSettings.orderedModules.filter { $0.hasSettings && moduleSettings.isVisible($0) }
    }

    var body: some View {
        List {
            Section("通用") {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    Label("外观与文字", systemImage: "textformat.size")
                }
                NavigationLink {
                    NotificationSettingsView()
                } label: {
                    Label("通知与提醒", systemImage: "bell.badge")
                }
                NavigationLink {
                    CloudSyncSettingsView()
                } label: {
                    Label("iCloud 同步", systemImage: "icloud")
                }
            }

            if !orderedModuleSettings.isEmpty {
                Section("模块设置") {
                    ForEach(orderedModuleSettings) { module in
                        NavigationLink {
                            moduleSettingsView(for: module)
                        } label: {
                            Label(module.title, systemImage: module.systemImage)
                        }
                    }
                }
            }

            Section("其他") {
                NavigationLink {
                    OCRTestView()
                } label: {
                    Label("文字识别测试", systemImage: "text.viewfinder")
                }
                NavigationLink {
                    HomeFeatureSettingsView()
                } label: {
                    Label("首页功能", systemImage: "switch.2")
                }
                NavigationLink {
                    StorageDataView()
                } label: {
                    Label("存储与数据", systemImage: "internaldrive")
                }
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("调试信息", systemImage: "ladybug")
                }
            }
        }
        .appNavigationTitle("设置")
        .iOSLabeledBackButton("我的")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
    }

    @ViewBuilder
    private func moduleSettingsView(for module: ToolModule) -> some View {
        switch module {
        case .myStocks:
#if MYTOOLS_FEATURE_STOCKS
            StockAppearanceSettingsView()
#else
            EmptyView()
#endif
#if MYTOOLS_FEATURE_BILLS
        case .bills:
            BillsExportSettingsView()
#else
        case .bills:
            EmptyView()
#endif
        case .personalFinance, .currencyExchange, .healthRecords, .foodMap, .secrets, .documents, .sportsLottery:
            EmptyView()
        }
    }
}

private struct _Unused: View { var body: some View { EmptyView() } }
