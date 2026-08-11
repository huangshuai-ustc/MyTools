#if MYTOOLS_FEATURE_HEALTH
import SwiftUI

struct HospitalDirectoryView: View {
    @EnvironmentObject private var store: HealthStore
    @EnvironmentObject private var auth: AuthManager
    @State private var query = ""
    @State private var editingProfile: HospitalProfile?

    private var displayedProfiles: [HospitalProfile] {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.hospitalProfiles
            .filter { profile in
                searchTerm.isEmpty
                    || profile.name.localizedCaseInsensitiveContains(searchTerm)
                    || profile.institutionTypeTitle.localizedCaseInsensitiveContains(searchTerm)
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
                    store.hospitalProfiles.isEmpty ? "暂无机构资料" : "没有匹配的机构",
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
                                .tint(.red)
                            }
                        }
                }
            }
        }
        .navigationTitle("医疗机构资料库")
        .iOSLabeledBackButton("健康档案")
        .searchable(text: $query, prompt: "搜索机构名称或分类")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                AdminEditAccessButton()
                if auth.isAdmin {
                    Button { editingProfile = HospitalProfile() } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新增机构")
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
            Image(systemName: profile.institutionTypeSystemImage)
                .foregroundStyle(.pink)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: AppListMetrics.recordContentSpacing) {
                Text(profile.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(profile.institutionTypeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if profile.supports(.hospital), profile.classificationTitles.isEmpty {
                    Text("未设置机构分类")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if profile.supports(.hospital) {
                    HospitalClassificationBadges(profile: profile)
                }
            }
            Spacer(minLength: 6)
            if showsEditIndicator {
                Image(systemName: "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HospitalProfileEditorView: View {
    @EnvironmentObject private var store: HealthStore
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
                Section("机构") {
                    LabeledContent("机构名称：") {
                        IMESafeTextField(prompt: "必填", text: $profile.name, alignment: .trailing)
                            .frame(maxWidth: 260)
                    }
                }
                Section("机构类别") {
                    ForEach(MedicalInstitutionType.allCases) { type in
                        Toggle(type.title, isOn: Binding(
                            get: { profile.supports(type) },
                            set: { profile.setSupport(type, enabled: $0) }
                        ))
                    }
                    if profile.supports(.hospital) {
                        Picker("机构级别：", selection: $profile.level) {
                            ForEach(HospitalLevel.displayOrder) { level in
                                Text(level.title).tag(level)
                            }
                        }
                        Picker("机构等次：", selection: $profile.grade) {
                            ForEach(HospitalGrade.displayOrder) { grade in
                                Text(grade.title).tag(grade)
                            }
                        }
                        Picker("医院性质：", selection: $profile.category) {
                            ForEach(HospitalCategory.allCases) { category in
                                Text(category.title).tag(category)
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "新增机构" : "编辑机构")
            .adminModeIndicator()
            .onChange(of: profile.institutionTypes) { _, _ in
                profile.normalizeClassification()
            }
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
            reportError("请填写机构名称。")
            return
        }
        guard !store.hospitalProfileNameExists(normalizedName, excluding: profile.id) else {
            reportError("医疗机构资料库中已经存在同名机构。")
            return
        }
        profile.name = normalizedName
        guard store.upsertHospitalProfile(profile) else {
            reportError("机构资料保存失败，请检查名称。")
            return
        }
        dismiss()
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}

#endif
