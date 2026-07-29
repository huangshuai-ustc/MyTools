import SwiftUI
import UniformTypeIdentifiers

struct ProfileView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var store: AppStore
    @State private var showAuth = false
    @State private var backupPasswordMode: BackupPasswordMode?
    @State private var exportDocument: VaultBackupDocument?
    @State private var pendingImportData: Data?
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var showingImportConfirmation = false
    @State private var showingBackupMessage = false
    @State private var backupMessage = ""
    @State private var importSucceeded = false
    @State private var isPreparingImport = false
    @State private var exportFilename = "备份"

    var body: some View {
        NavigationStack {
            List {
                Section("管理员") {
                    if auth.isAdmin {
                        Label("管理员模式已开启", systemImage: "checkmark.shield.fill")
                        Button("退出管理员模式") { auth.lock() }
                    } else {
                        Button { showAuth = true } label: {
                            Label("进入管理员模式", systemImage: "lock.shield")
                        }
                    }
                }
                Section("备份与恢复") {
                    Button {
                        backupPasswordMode = .export
                    } label: {
                        Label("导出加密备份", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!auth.isAdmin || isPreparingImport)

                    Button {
                        showingImportConfirmation = true
                    } label: {
                        Label("从文件导入备份", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!auth.isAdmin || isPreparingImport)

                    if isPreparingImport {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取备份")
                        }
                        .foregroundStyle(.secondary)
                    }

                    if !auth.isAdmin {
                        Text("进入管理员模式后可以导出或导入备份。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("设置") {
                    NavigationLink {
                        ProfileSettingsView()
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }
                Section("存储与安全说明") {
                    Label("本地优先存储", systemImage: "internaldrive")
                    Label("备份文件使用 AES-GCM 加密", systemImage: "lock.rotation")
                }
                Section("关于") {
                    LabeledContent("版本", value: "MVP 2.2.2")
                }
            }
            .navigationTitle("我的")
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .listStyle(.insetGrouped)
#endif
            .sheet(isPresented: $showAuth) {
                AuthenticationView()
                    .iOSAuthenticationSheet()
            }
            .sheet(item: $backupPasswordMode, onDismiss: finishBackupPasswordFlow) { mode in
                BackupPasswordView(mode: mode) { password in
                    await handleBackupPassword(password, mode: mode)
                }
                .iOSAuthenticationSheet()
            }
            .alert(
                "导入备份",
                isPresented: $showingImportConfirmation,
            ) {
                Button("选择备份文件") {
                    showingImporter = true
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("导入会替换当前全部银行、股票、换汇、健康档案和保密资料数据。")
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .myToolsBackup,
                defaultFilename: exportFilename
            ) { result in
                exportDocument = nil
                switch result {
                case .success:
                    reportBackupMessage("加密备份已保存。")
                case .failure(let error):
                    reportBackupMessage(error.localizedDescription)
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.myToolsBackup],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    prepareImport(from: url)
                case .failure(let error):
                    reportBackupMessage(error.localizedDescription)
                }
            }
            .alert("备份", isPresented: $showingBackupMessage) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(backupMessage)
            }
        }
    }

    private func handleBackupPassword(_ password: String, mode: BackupPasswordMode) async -> String? {
        do {
            switch mode {
            case .export:
                exportDocument = try await store.makeBackupDocument(password: password)
                exportFilename = backupFilename(for: Date())
            case .restore:
                guard let pendingImportData else { throw VaultBackupError.invalidFile }
                try await store.restoreBackup(from: pendingImportData, password: password)
                self.pendingImportData = nil
                importSucceeded = true
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func finishBackupPasswordFlow() {
        if exportDocument != nil {
            showingExporter = true
        }
        if importSucceeded {
            importSucceeded = false
            reportBackupMessage("备份导入成功，本地数据已更新。")
        }
    }

    private func prepareImport(from url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        isPreparingImport = true
        Task { @MainActor in
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                isPreparingImport = false
            }
            do {
                pendingImportData = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                backupPasswordMode = .restore
            } catch {
                pendingImportData = nil
                reportBackupMessage(error.localizedDescription)
            }
        }
    }

    private func reportBackupMessage(_ message: String) {
        backupMessage = message
        showingBackupMessage = true
    }

    private func backupFilename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyyMMddHHmm"
        return formatter.string(from: date) + ".mytools"
    }
}

private struct ProfileSettingsView: View {
    var body: some View {
        List {
            Section("功能设置") {
                NavigationLink {
                    HomeFeatureSettingsView()
                } label: {
                    Label("首页功能", systemImage: "switch.2")
                }
                NavigationLink {
                    StockAppearanceSettingsView()
                } label: {
                    Label(ToolModule.myStocks.title, systemImage: "chart.line.uptrend.xyaxis")
                }
            }
            Section("诊断") {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("调试信息", systemImage: "ladybug")
                }
            }
        }
        .navigationTitle("设置")
        .adminModeIndicator()
        .iOSLabeledBackButton("我的")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
    }
}

private struct HomeFeatureSettingsView: View {
    @EnvironmentObject private var moduleSettings: ToolModuleSettings

    var body: some View {
        List {
            Section("首页功能") {
                ForEach(moduleSettings.orderedModules) { module in
                    Toggle(isOn: visibilityBinding(for: module)) {
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
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onMove(perform: moduleSettings.moveModules)
            }
            }
            .navigationTitle("首页功能")
            .adminModeIndicator()
            .iOSLabeledBackButton("设置")
#if os(iOS)
        .toolbar { EditButton() }
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
    }

    private func visibilityBinding(for module: ToolModule) -> Binding<Bool> {
        Binding(
            get: { moduleSettings.isVisible(module) },
            set: { moduleSettings.setVisible($0, for: module) }
        )
    }
}

private struct StockAppearanceSettingsView: View {
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings

    var body: some View {
        List {
            Section {
                schemePicker(title: "A 股", market: .aShare)
                schemePicker(title: "港股", market: .hongKong)
                schemePicker(title: "美股", market: .unitedStates)
            } header: {
                Text("涨跌颜色")
            } footer: {
                Text("默认遵循市场习惯：A 股和港股红涨绿跌，美股绿涨红跌。盈亏颜色会使用对应股票市场的设置。")
            }
        }
        .navigationTitle(ToolModule.myStocks.title)
        .adminModeIndicator()
        .iOSLabeledBackButton("设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
    }

    private func schemePicker(title: String, market: StockMarket) -> some View {
        Picker(title, selection: schemeBinding(for: market)) {
            ForEach(StockRiseFallColorScheme.allCases) { scheme in
                Text(scheme.title).tag(scheme)
            }
        }
    }

    private func schemeBinding(for market: StockMarket) -> Binding<StockRiseFallColorScheme> {
        Binding(
            get: { stockAppearanceSettings.scheme(for: market) },
            set: { stockAppearanceSettings.setScheme($0, for: market) }
        )
    }
}

enum BackupPasswordMode: Int, Identifiable {
    case export
    case restore

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .export: return "设置备份密码"
        case .restore: return "输入备份密码"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .export: return "继续导出"
        case .restore: return "解密并导入"
        }
    }
}

struct BackupPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    let mode: BackupPasswordMode
    let onSubmit: (String) async -> String?
    @State private var password = VaultBackupCrypto.defaultPassword
    @State private var confirmation = VaultBackupCrypto.defaultPassword
    @State private var error = ""
    @State private var isSubmitting = false
    @FocusState private var inputFocused: Bool

    private var canSubmit: Bool {
        guard password.isEmpty || password.count >= 8 else { return false }
        return mode == .restore
            || password.isEmpty
            || password == confirmation
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("留空时使用默认密码", text: $password)
                        .focused($inputFocused)
                    if mode == .export {
                        SecureField("再次输入", text: $confirmation)
                            .focused($inputFocused)
                    }
                } footer: {
                    Text(mode == .export ? "已填入默认密码.；清空后导出也会使用该默认密码。自定义密码至少 8 位。" : "已填入默认密码；清空后导入也会尝试该默认密码。")
                }

                if !error.isEmpty {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(mode.title)
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: requestSubmit) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(mode.confirmationTitle)
                        }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func requestSubmit() {
        commitPendingTextInput {
            guard !isSubmitting else { return }
            isSubmitting = true
            let submittedPassword = password
            Task { @MainActor in
                if let message = await onSubmit(submittedPassword) {
                    error = message
                    isSubmitting = false
                } else {
                    dismiss()
                }
            }
        }
    }
}
