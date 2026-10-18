import SwiftUI

struct CloudSyncSettingsView: View {
    @EnvironmentObject private var cloudSync: CloudSyncCoordinator
    @State private var isConfirmingPausedDeletions = false

    var body: some View {
        List {
            Section {
                ToggleFieldRow(title: "iCloud 同步", isOn: syncEnabled)
            } footer: {
                Text("开启后，首页模块开关和排序，以及银行、股票、换汇、健康档案、保密资料和附件会保存到当前 Apple 账户的 CloudKit 私有数据库。行情缓存、汇率缓存、诊断日志和设备认证状态不会上传。")
#if os(macOS)
                    .fixedSize(horizontal: false, vertical: true)
#endif
            }

            Section("同步状态") {
                AppLabeledContentRow("状态") {
                    HStack(spacing: 8) {
                        if cloudSync.status.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(cloudSync.status.title)
                    }
                }

                if let date = cloudSync.lastSuccessfulSyncAt {
                    DetailValueRow(
                        title: "最近成功同步",
                        value: date.formatted(date: .abbreviated, time: .shortened)
                    )
                }

                Button {
                    cloudSync.synchronizeNow()
                } label: {
                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!cloudSync.canSynchronizeNow)

                if let detail = cloudSync.errorDetail {
                    Text(detail)
                        .appFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                if case .deletionPaused = cloudSync.status {
                    Button(role: .destructive) {
                        isConfirmingPausedDeletions = true
                    } label: {
                        Label("确认删除", systemImage: "trash")
                    }
                    .confirmationDialog(
                        "确认删除 iCloud 中的这些记录？",
                        isPresented: $isConfirmingPausedDeletions,
                        titleVisibility: .visible
                    ) {
                        Button("删除", role: .destructive) {
                            cloudSync.confirmPausedDeletions()
                        }
                    } message: {
                        Text("删除会同步到同一账户的其他设备。如不确定，请先导出加密备份。")
                    }
                }
            }
        }
        .appNavigationTitle("iCloud 同步")
        .iOSLabeledBackButton("设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
    }

    private var syncEnabled: Binding<Bool> {
        Binding(
            get: { cloudSync.isEnabled },
            set: { cloudSync.setEnabled($0) }
        )
    }
}
