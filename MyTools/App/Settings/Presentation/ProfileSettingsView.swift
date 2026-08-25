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
                    AdminSessionSettingsView()
                } label: {
                    Label("管理员模式", systemImage: "lock.shield")
                }
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
        .adminModeIndicator()
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

private struct AdminSessionSettingsView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var customMinutesText = ""

    var body: some View {
        List {
            Section {
                Picker("认证有效期", selection: durationBinding) {
                    ForEach(AdminSessionDuration.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }

                if auth.sessionDuration == .custom {
                    TextField("分钟", text: $customMinutesText)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                        .onSubmit(commitCustomMinutes)
                        .onChange(of: customMinutesText) { _, value in
                            guard value.count > 6 else { return }
                            customMinutesText = String(value.prefix(6))
                        }
                        .onDisappear(perform: commitCustomMinutes)
                }
                Toggle("进入后台锁定", isOn: lockOnBackgroundBinding)
            } header: {
                Text("管理员会话")
            } footer: {
                Text(sessionDescription)
            }

            Section("说明") {
                Text("认证方式保持不变，仍可使用管理员密码、Face ID、Touch ID 或设备密码。临时查看敏感信息仍需单独认证，不会改变管理员会话。")
                    .appFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .appNavigationTitle("管理员模式")
        .adminModeIndicator()
        .iOSLabeledBackButton("设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .onAppear {
            customMinutesText = String(auth.customSessionDurationMinutes)
        }
    }

    private var durationBinding: Binding<AdminSessionDuration> {
        Binding(
            get: { auth.sessionDuration },
            set: { auth.updateSessionDuration($0) }
        )
    }

    private var lockOnBackgroundBinding: Binding<Bool> {
        Binding(
            get: { auth.lockOnBackground },
            set: { auth.updateLockOnBackground($0) }
        )
    }

    private var sessionDescription: String {
        if auth.sessionDuration == .permanent {
            return auth.lockOnBackground
                ? "认证后持续有效，App 进入后台时锁定。"
                : "认证后持续有效，直到主动退出或彻底关闭 App。"
        }
        let duration = auth.sessionDuration == .custom
            ? "\(auth.customSessionDurationMinutes) 分钟"
            : auth.sessionDuration.title
        return auth.lockOnBackground
            ? "认证后最多保持 \(duration)，App 进入后台时锁定。"
            : "认证后保持 \(duration)，期间进入后台不会锁定。"
    }

    private func commitCustomMinutes() {
        guard let minutes = Int(customMinutesText) else {
            customMinutesText = String(auth.customSessionDurationMinutes)
            return
        }
        auth.updateCustomSessionDurationMinutes(minutes)
        customMinutesText = String(auth.customSessionDurationMinutes)
    }
}
