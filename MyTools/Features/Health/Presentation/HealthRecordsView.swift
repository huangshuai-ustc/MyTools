#if MYTOOLS_FEATURE_HEALTH
import SwiftUI

struct HealthRecordsView: View {
    private static let pageSize = 30
    @EnvironmentObject private var store: HealthStore
    @State private var query = ""
    @State private var selectedTag = ""
    @State private var selectedYear: Int?
    @State private var editingRecord: MedicalRecord?
    @State private var pagination = AppListPagination(pageSize: HealthRecordsView.pageSize)

    private var presentation: MedicalRecordsPresentation {
        MedicalRecordsPresentation(
            records: store.medicalRecords,
            query: query,
            selectedTag: selectedTag,
            selectedYear: selectedYear,
            calendar: calendar
        )
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .autoupdatingCurrent
        return value
    }

    var body: some View {
        let presentation = presentation
        let visitGroups = presentation.visitGroups
        let pagedVisitGroups = pagination.visibleItems(from: visitGroups)
        let yearGroups = presentation.yearGroups(from: pagedVisitGroups)
        List {
            Section("健康总览") {
                PickerFieldRow(title: "统计范围", selection: $selectedYear) {
                    Text("全部").tag(nil as Int?)
                    ForEach(presentation.availableYears, id: \.self) { year in
                        Text(verbatim: "\(year) 年").tag(year as Int?)
                    }
                }

                overviewMetrics(presentation.overview)
                    .appListRowStyle()
            }

            Section {
                NavigationLink {
                    HospitalDirectoryView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "building.2")
                            .foregroundStyle(.pink)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("医疗机构资料库")
                            Text("\(store.hospitalProfiles.count) 家机构")
                                .appFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !presentation.allTags.isEmpty {
                Section("标签筛选") {
                    AppTagFilterCapsules(tags: presentation.allTags, selectedTag: $selectedTag)
                }
            }

            if visitGroups.isEmpty {
                Section {
                    ContentUnavailableView(
                        store.medicalRecords.isEmpty ? "暂无健康记录" : "没有匹配的健康记录",
                        systemImage: store.medicalRecords.isEmpty ? "cross.case" : "magnifyingglass",
                        description: Text(store.medicalRecords.isEmpty ? "点右上角编辑并验证身份后记录第一次就诊、购药、体检或住院" : "请尝试其他机构、药房、体检项目、住院记录、诊断、费用项目或标签")
                    )
                }
            }

            ForEach(yearGroups) { group in
                Section {
                    ForEach(group.visitGroups) { visitGroup in
                        recordLink(
                            visitGroup.originalVisit,
                            isFollowUp: visitGroup.originalVisit.isFollowUp,
                            followUpCount: visitGroup.followUps.count,
                            relatedPharmacyPurchaseCount: visitGroup.pharmacyPurchases.count,
                            displayedTotalCost: visitGroup.costSummary.totalCost
                        )
                        .onAppear {
                            pagination.loadMoreIfNeeded(
                                currentItemID: visitGroup.id,
                                lastVisibleItemID: pagedVisitGroups.last?.id,
                                totalItemCount: visitGroups.count
                            )
                        }
                    }
                } header: {
                    Text(verbatim: "\(group.year) 年")
                }
            }

        }
        .appNavigationTitle("健康档案")
        .iOSLabeledBackButton("工具")
        .searchable(text: $query, prompt: "搜索机构、药房、诊断、费用项目或标签")
        .onChange(of: query) { _, _ in pagination.reset() }
        .onChange(of: selectedTag) { _, _ in pagination.reset() }
        .onChange(of: selectedYear) { _, _ in pagination.reset() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { editingRecord = MedicalRecord() } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新增健康记录")
            }
        }
#if os(iOS)
        .appAdaptiveLargeNavigationTitle()
        .listStyle(.insetGrouped)
#endif
        .sheet(item: $editingRecord) { record in
            MedicalRecordEditorView(record: record, isNew: true)
                .id(record.id)
                .iOSLargeSheet()
        }
    }

    private func overviewMetrics(_ summary: MedicalOverviewSnapshot) -> some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    summaryMetric("机构", value: "\(summary.hospitalCount) 家")
                    summaryMetric("就诊/体检", value: "\(summary.visitCount) 次")
                    summaryMetric("总费用", value: MedicalValueFormatter.money(summary.total))
                }
                VStack(alignment: .leading, spacing: 9) {
                    summaryMetric("机构", value: "\(summary.hospitalCount) 家")
                    summaryMetric("就诊/体检", value: "\(summary.visitCount) 次")
                    summaryMetric("总费用", value: MedicalValueFormatter.money(summary.total))
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    summaryMetricWithRatio(
                        "医保费用",
                        amount: summary.insurance,
                        ratio: summary.insuranceRatio,
                        color: .blue
                    )
                    summaryMetricWithRatio(
                        "自费费用",
                        amount: summary.selfPay,
                        ratio: summary.selfPayRatio,
                        color: .orange
                    )
                }
                VStack(alignment: .leading, spacing: 9) {
                    summaryMetricWithRatio(
                        "医保费用",
                        amount: summary.insurance,
                        ratio: summary.insuranceRatio,
                        color: .blue
                    )
                    summaryMetricWithRatio(
                        "自费费用",
                        amount: summary.selfPay,
                        ratio: summary.selfPayRatio,
                        color: .orange
                    )
                }
            }
        }
    }

    private func summaryMetric(_ title: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).appFont(.caption).foregroundStyle(.secondary)
            Text(value)
                .appFont(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryMetricWithRatio(
        _ title: String,
        amount: Decimal,
        ratio: Decimal,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).appFont(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(MedicalValueFormatter.money(amount))
                    .appFont(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("(\(MedicalValueFormatter.percentage(ratio)))")
                    .appFont(.caption2.monospacedDigit())
                    .foregroundStyle(color.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recordLink(
        _ record: MedicalRecord,
        isFollowUp: Bool,
        followUpCount: Int = 0,
        relatedPharmacyPurchaseCount: Int = 0,
        displayedTotalCost: Decimal? = nil
    ) -> some View {
        NavigationLink {
            MedicalRecordDetailView(recordID: record.id)
        } label: {
            MedicalRecordRow(
                record: record,
                isFollowUp: isFollowUp,
                followUpCount: followUpCount,
                relatedPharmacyPurchaseCount: relatedPharmacyPurchaseCount,
                displayedTotalCost: displayedTotalCost ?? record.totalCost
            )
        }
        .appListRowStyle()
        .appDeleteSwipeAction(isEnabled: true) {
            store.deleteMedicalRecords(ids: [record.id])
        }
    }
}

#endif
