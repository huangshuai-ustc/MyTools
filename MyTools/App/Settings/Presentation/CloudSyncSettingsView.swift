import SwiftUI

struct CloudSyncSettingsView: View {
    @EnvironmentObject private var cloudSync: CloudSyncCoordinator
    @EnvironmentObject private var auth: AuthManager
    @State private var showingRebuildConfirmation = false

    var body: some View {
        List {
            Section {
                Toggle("iCloud 同步", isOn: syncEnabled)
                    .disabled(cloudSync.isRebuildingCloudData)
            } footer: {
                Text("开启后，首页模块开关和排序，以及银行、股票、换汇、健康档案、保密资料和附件会保存到当前 Apple 账户的 CloudKit 私有数据库。行情缓存、汇率缓存、诊断日志和设备认证状态不会上传。")
#if os(macOS)
                    .fixedSize(horizontal: false, vertical: true)
#endif
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
                        .appFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    showingRebuildConfirmation = true
                } label: {
                    if cloudSync.isRebuildingCloudData {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在重建 iCloud 数据")
                    } else {
                        Label(
                            "重建 iCloud 数据",
                            systemImage: "icloud.and.arrow.up"
                        )
                    }
                }
                .disabled(!auth.isAdmin || !cloudSync.canRebuildCloudData)

                if !auth.isAdmin {
                    Text("进入管理员模式后才能重建 iCloud 数据。")
                        .appFont(.footnote)
                        .foregroundStyle(.secondary)
                } else if !cloudSync.isEnabled {
                    Text("请先开启 iCloud 同步。重建只清理云端数据，不会删除本机档案。")
                        .appFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("云端维护")
            } footer: {
                Text("重建会删除本 App 的 CloudKit 私有数据区及云端附件，再从本机资料重新上传。其他设备升级到支持重建协议的版本后会自动暂停同步；仍在使用旧版本的设备必须先关闭同步。请确认本机资料完整；Apple 回收历史版本可能需要一段时间。")
#if os(macOS)
                        .fixedSize(horizontal: false, vertical: true)
#endif
            }
        }
        .appNavigationTitle("iCloud 同步")
        .adminModeIndicator()
        .iOSLabeledBackButton("设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .sheet(isPresented: $showingRebuildConfirmation) {
            CloudDataRebuildConfirmationView {
                guard auth.isAdmin else { return }
                cloudSync.rebuildCloudData()
            }
        }
    }

    private var syncEnabled: Binding<Bool> {
        Binding(
            get: { cloudSync.isEnabled },
            set: { cloudSync.setEnabled($0) }
        )
    }
}

private struct CloudDataRebuildConfirmationView: View {
    private enum Stage {
        case first
        case second
    }

    @Environment(\.dismiss) private var dismiss
    let rebuild: () -> Void
    @State private var stage: Stage = .first
    @State private var unlockAt = Date().addingTimeInterval(10)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: stage == .first
                        ? "exclamationmark.triangle.fill"
                        : "icloud.and.arrow.up")
                        .appFont(.system(size: 34))
                        .foregroundStyle(.orange)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stage == .first ? "确认重建范围" : "最后确认")
                            .appFont(.title3.weight(.semibold))
                        Text("第 \(stage == .first ? 1 : 2) 层，共 2 层")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(message)
                    .fixedSize(horizontal: false, vertical: true)

                if stage == .second {
                    Label(
                        "本机档案和附件不会删除；重建完成后以本机资料重新上传。",
                        systemImage: "lock.doc"
                    )
                    .appFont(.footnote)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let seconds = remainingSeconds(at: context.date)
                    Button(role: stage == .second ? .destructive : nil) {
                        guard context.date >= unlockAt else { return }
                        if stage == .first {
                            stage = .second
                            unlockAt = Date().addingTimeInterval(10)
                        } else {
                            rebuild()
                            dismiss()
                        }
                    } label: {
                        Text(buttonTitle(seconds: seconds))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(stage == .second ? .red : .accentColor)
                    .controlSize(.large)
                    .disabled(seconds > 0)
                }
            }
            .padding(24)
            .appNavigationTitle("重建 iCloud 数据")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 390)
#if os(iOS)
        .presentationDetents([.medium])
#endif
    }

    private var message: String {
        switch stage {
        case .first:
            return "这会删除本 App 在当前 Apple 账户中的 CloudKit 私有数据区、业务记录和云端附件，然后从本机资料重新同步。请先确认本机资料完整，并确认其他设备已升级到支持重建协议的版本；旧版本设备必须关闭同步。"
        case .second:
            return "云端删除不可撤销，Apple 的存储用量回收也可能延迟。确认后请保持本机 App 打开并等待同步完成。"
        }
    }

    private func remainingSeconds(at date: Date) -> Int {
        max(0, Int(ceil(unlockAt.timeIntervalSince(date))))
    }

    private func buttonTitle(seconds: Int) -> String {
        if seconds > 0 {
            return stage == .first
                ? "继续（\(seconds)）"
                : "重建 iCloud 数据（\(seconds)）"
        }
        return stage == .first ? "继续" : "重建 iCloud 数据"
    }
}
