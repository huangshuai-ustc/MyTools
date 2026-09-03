import SwiftUI
import UniformTypeIdentifiers

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore
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
                Section("设置") {
                    NavigationLink {
                        ProfileSettingsView()
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }

                Section("数据与备份") {
                    Button {
                        backupPasswordMode = .export
                    } label: {
                        Label("导出加密备份", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isPreparingImport)

                    Button {
                        showingImportConfirmation = true
                    } label: {
                        Label("从文件导入备份", systemImage: "square.and.arrow.down")
                    }
                    .disabled(isPreparingImport)

                    if isPreparingImport {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取备份")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                Section("关于") {
                    DetailValueRow(title: "版本", value: AppMetadata.versionDescription)
                }
            }
            .appNavigationTitle("我的")
#if os(iOS)
        .appAdaptiveLargeNavigationTitle()
            .listStyle(.insetGrouped)
#endif
            .sheet(item: $backupPasswordMode, onDismiss: finishBackupPasswordFlow) { mode in
                BackupPasswordView(
                    mode: mode,
                    defaultPassword: nil
                ) { password in
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
            let effectivePassword = password.isEmpty ? nil : password
            guard let effectivePassword else {
                throw VaultBackupError.missingPassword
            }
            switch mode {
            case .export:
                exportDocument = try await store.makeBackupDocument(password: effectivePassword)
                exportFilename = backupFilename(for: Date())
            case .restore:
                guard let pendingImportData else { throw VaultBackupError.invalidFile }
                try await store.restoreBackup(from: pendingImportData, password: effectivePassword)
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
