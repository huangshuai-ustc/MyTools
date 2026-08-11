import SwiftUI

struct CloudSyncSettingsView: View {
    @EnvironmentObject private var cloudSync: CloudSyncCoordinator

    var body: some View {
        List {
            Section {
                Toggle("iCloud 同步", isOn: syncEnabled)
            } footer: {
                Text("开启后，银行、股票、换汇、健康档案、保密资料和附件会保存到当前 Apple 账户的 CloudKit 私有数据库。行情缓存、汇率缓存、诊断日志和设备认证状态不会上传。")
            }

            Section("同步状态") {
                LabeledContent("状态") {
                    HStack(spacing: 8) {
                        if cloudSync.status.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(cloudSync.status.title)
                    }
                }

                if let date = cloudSync.lastSuccessfulSyncAt {
                    LabeledContent(
                        "最近成功同步",
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
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("iCloud 同步")
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
