import SwiftUI

struct HospitalDirectoryView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var editingProfile: HospitalProfile?

    private var displayedProfiles: [HospitalProfile] {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.hospitalProfiles
            .filter { profile in
                searchTerm.isEmpty
                    || profile.name.localizedCaseInsensitiveContains(searchTerm)
                    || profile.classificationTitles.contains {
                        $0.localizedCaseInsensitiveContains(searchTerm)
                    }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if displayedProfiles.isEmpty {
                ContentUnavailableView(
                    store.hospitalProfiles.isEmpty ? "暂无医院资料" : "没有匹配的医院",
                    systemImage: store.hospitalProfiles.isEmpty ? "building.2" : "magnifyingglass"
                )
            } else {
                ForEach(displayedProfiles) { profile in
                    HospitalProfileRow(profile: profile, showsEditIndicator: auth.isAdmin)
                        .appListRowStyle()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if auth.isAdmin { editingProfile = profile }
                        }
                        .swipeActions {
                            if auth.isAdmin {
                                Button(role: .destructive) {
                                    store.deleteHospitalProfiles(ids: [profile.id])
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                }
            }
        }
        .navigationTitle("医院资料库")
        .iOSLabeledBackButton("健康档案")
        .searchable(text: $query, prompt: "搜索医院名称或分类")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                AdminEditAccessButton { editingProfile = HospitalProfile() }
                if auth.isAdmin {
                    Button { editingProfile = HospitalProfile() } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新增医院")
                }
            }
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .sheet(item: $editingProfile) { profile in
            HospitalProfileEditorView(
                profile: profile,
                isNew: !store.hospitalProfiles.contains { $0.id == profile.id }
            )
            .id(profile.id)
            .iOSLargeSheet()
        }
    }
}

private struct HospitalProfileRow: View {
    let profile: HospitalProfile
    let showsEditIndicator: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "building.2.fill")
                .foregroundStyle(.pink)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
                Text(profile.name)
                    .font(.headline)
                    .lineLimit(2)
                if profile.classificationTitles.isEmpty {
                    Text("未设置医院分类")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HospitalClassificationBadges(profile: profile)
                }
            }
            Spacer(minLength: 6)
            if showsEditIndicator {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HospitalProfileEditorView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var profile: HospitalProfile
    @State private var showingAuthentication = false
    @State private var showingError = false
    @State private var errorMessage = ""
    let isNew: Bool

    init(profile: HospitalProfile, isNew: Bool) {
        _profile = State(initialValue: profile)
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("医院") {
                    LabeledContent("医院名称：") {
                        IMESafeTextField(prompt: "必填", text: $profile.name, alignment: .trailing)
                            .frame(maxWidth: 260)
                    }
                    Picker("医院级别：", selection: $profile.level) {
                        ForEach(HospitalLevel.displayOrder) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    Picker("医院等次：", selection: $profile.grade) {
                        ForEach(HospitalGrade.displayOrder) { grade in
                            Text(grade.title).tag(grade)
                        }
                    }
                    Picker("医院类型：", selection: $profile.category) {
                        ForEach(HospitalCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "新增医院" : "编辑医院")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commitPendingTextInput { requestSave() } }
                }
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView(onAuthenticated: save)
                    .iOSAuthenticationSheet()
            }
            .alert("无法保存", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func requestSave() {
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }
        save()
    }

    private func save() {
        let normalizedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            reportError("请填写医院名称。")
            return
        }
        guard !store.hospitalProfileNameExists(normalizedName, excluding: profile.id) else {
            reportError("医院资料库中已经存在同名医院。")
            return
        }
        profile.name = normalizedName
        guard store.upsertHospitalProfile(profile) else {
            reportError("医院资料保存失败，请检查名称。")
            return
        }
        dismiss()
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}
