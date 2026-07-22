import SwiftUI
import UniformTypeIdentifiers

struct ProfileView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var store: CardStore
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

    var body: some View {
        NavigationStack {
            List {
                Section("管理员") {
                    if auth.isAdmin {
                        Label("管理员模式已开启", systemImage: "checkmark.shield.fill")
                        NavigationLink("管理银行账户") { AdminCardsView() }
                        Button("退出管理员模式") { auth.lock() }
                    } else {
                        Button { showAuth = true } label: {
                            Label("进入管理员模式", systemImage: "lock.shield")
                        }
                    }
                }
                Section("数据与安全") {
                    Label("本地优先存储", systemImage: "internaldrive")
                    Label("备份文件使用 AES-GCM 加密", systemImage: "lock.rotation")
                    Button {
                        backupPasswordMode = .export
                    } label: {
                        Label("导出加密备份", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!auth.isAdmin)

                    Button {
                        showingImportConfirmation = true
                    } label: {
                        Label("从文件导入备份", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!auth.isAdmin)

                    if !auth.isAdmin {
                        Text("进入管理员模式后可以导出或导入备份。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("关于") {
                    LabeledContent("版本", value: "MVP 1.0")
                }
            }
            .navigationTitle("我的")
#if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .listStyle(.insetGrouped)
#endif
            .sheet(isPresented: $showAuth) {
                AuthenticationView()
                    .iOSLargeSheet()
            }
            .sheet(item: $backupPasswordMode, onDismiss: finishBackupPasswordFlow) { mode in
                BackupPasswordView(mode: mode) { password in
                    handleBackupPassword(password, mode: mode)
                }
                .iOSLargeSheet()
            }
            .confirmationDialog(
                "导入会替换当前全部账户和银行卡数据",
                isPresented: $showingImportConfirmation,
                titleVisibility: .visible
            ) {
                Button("选择备份文件", role: .destructive) {
                    showingImporter = true
                }
                Button("取消", role: .cancel) {}
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .myToolsBackup,
                defaultFilename: "我的工具箱备份"
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

    private func handleBackupPassword(_ password: String, mode: BackupPasswordMode) -> String? {
        do {
            switch mode {
            case .export:
                exportDocument = try store.makeBackupDocument(password: password)
            case .restore:
                guard let pendingImportData else { throw VaultBackupError.invalidFile }
                try store.restoreBackup(from: pendingImportData, password: password)
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
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            pendingImportData = try Data(contentsOf: url, options: .mappedIfSafe)
            backupPasswordMode = .restore
        } catch {
            pendingImportData = nil
            reportBackupMessage(error.localizedDescription)
        }
    }

    private func reportBackupMessage(_ message: String) {
        backupMessage = message
        showingBackupMessage = true
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
    let onSubmit: (String) -> String?
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error = ""

    private var canSubmit: Bool {
        password.count >= 8 && (mode == .restore || password == confirmation)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("至少 8 位", text: $password)
                    if mode == .export {
                        SecureField("再次输入", text: $confirmation)
                    }
                } footer: {
                    Text(mode == .export ? "此密码用于加密备份文件，丢失后无法恢复。" : "导入成功后会替换当前全部本地数据。")
                }

                if !error.isEmpty {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(mode.title)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode.confirmationTitle) {
                        if let message = onSubmit(password) {
                            error = message
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }
}
