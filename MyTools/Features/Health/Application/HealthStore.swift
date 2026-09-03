#if MYTOOLS_FEATURE_HEALTH
import Foundation
import UniformTypeIdentifiers

@MainActor
final class HealthStore: ObservableObject, ModuleLifecycleParticipant, ModuleDataCleanupParticipant, AttachmentManaging {
    @Published private(set) var medicalRecords: [MedicalRecord]
    @Published private(set) var hospitalProfiles: [HospitalProfile]
    @Published private(set) var knownTags: [String]

    let attachmentStore: AttachmentStore
    private var isModuleVisible: Bool
    private weak var mutationNotifier: (any VaultMutationNotifying)?

    init(
        medicalRecords: [MedicalRecord] = [],
        hospitalProfiles: [HospitalProfile] = [],
        knownTags: [String] = [],
        attachmentStore: AttachmentStore,
        isModuleVisible: Bool = true
    ) {
        let normalizedRecords = medicalRecords.map(Self.normalizedTags(in:))
        self.medicalRecords = normalizedRecords
        self.hospitalProfiles = hospitalProfiles
        self.knownTags = AppTagSupport.merged(knownTags, with: normalizedRecords.flatMap(\.tags))
        self.attachmentStore = attachmentStore
        self.isModuleVisible = isModuleVisible
    }

    func attach(mutationNotifier: any VaultMutationNotifying) {
        self.mutationNotifier = mutationNotifier
    }

    func replace(
        medicalRecords: [MedicalRecord],
        hospitalProfiles: [HospitalProfile],
        knownTags: [String]? = nil
    ) {
        let normalizedRecords = medicalRecords.map(Self.normalizedTags(in:))
        self.medicalRecords = normalizedRecords
        self.hospitalProfiles = hospitalProfiles
        self.knownTags = AppTagSupport.merged(
            knownTags ?? self.knownTags,
            with: normalizedRecords.flatMap(\.tags)
        )
        DiagnosticLogger.shared.log(.data, "健康数据替换 records=\(normalizedRecords.count) hospitals=\(hospitalProfiles.count)")
    }

    func moduleVisibilityChanged(isVisible: Bool) {
        guard isVisible else { return }
        synchronizeLoadedRecords()
    }

    var observedModules: Set<ToolModule> { [.healthRecords] }
    var cleanupModule: ToolModule { .healthRecords }

    func moduleDidChange(_ module: ToolModule, isEnabled: Bool) {
        isModuleVisible = isEnabled
        moduleVisibilityChanged(isVisible: isEnabled)
    }

    func scanRedundantData() -> [RedundantDataFinding] {
        var findings: [RedundantDataFinding] = []

        let dischargeDateRecords = medicalRecords.filter {
            !$0.isInpatientEpisode && $0.inpatientEndDate != nil
        }.count
        appendFinding(
            to: &findings,
            ruleID: "non-episode-discharge-date",
            title: "非住院主记录的出院日期",
            detail: "出院日期只属于住院主记录。",
            recordCount: dischargeDateRecords,
            fieldCount: dischargeDateRecords
        )

        let examDetailRecords = medicalRecords.filter {
            !$0.isPhysicalExam && $0.physicalExamDetails != nil
        }.count
        appendFinding(
            to: &findings,
            ruleID: "non-exam-details",
            title: "非体检记录的体检详情",
            detail: "体检套餐、项目和结论只属于体检记录。",
            recordCount: examDetailRecords,
            fieldCount: examDetailRecords
        )

        let classificationRecords = medicalRecords.filter {
            $0.institutionType != .hospital && classificationFieldCount(in: $0) > 0
        }
        appendFinding(
            to: &findings,
            ruleID: "non-hospital-classification",
            title: "非医院记录的医院分类",
            detail: "药房和体检机构不使用医院级别、等次或性质。",
            recordCount: classificationRecords.count,
            fieldCount: classificationRecords.reduce(0) { $0 + classificationFieldCount(in: $1) }
        )

        return findings
    }

    func cleanupRedundantData() {
        for index in medicalRecords.indices {
            if !medicalRecords[index].isInpatientEpisode {
                medicalRecords[index].inpatientEndDate = nil
            }
            if !medicalRecords[index].isPhysicalExam {
                medicalRecords[index].physicalExamDetails = nil
            }
            medicalRecords[index].normalizeInstitutionClassification()
        }
    }

    func synchronizeLoadedRecords() {
        let synchronization = HealthRecordSynchronizer.synchronizeLoadedRecords(
            medicalRecords: medicalRecords,
            hospitalProfiles: hospitalProfiles,
            isEnabled: isModuleVisible
        )
        guard synchronization.didChange else { return }
        medicalRecords = synchronization.medicalRecords
        hospitalProfiles = synchronization.hospitalProfiles
        didMutate()
    }

    func upsertMedicalRecord(_ record: MedicalRecord) {
        var storedRecord = record
        storedRecord.normalizeInstitutionClassification()
        storedRecord.hospital = storedRecord.hospital.trimmingCharacters(in: .whitespacesAndNewlines)
        knownTags = AppTagSupport.merged(knownTags, with: storedRecord.tags)
        let isUpdate: Bool
        if let index = medicalRecords.firstIndex(where: { $0.id == storedRecord.id }) {
            let retainedIDs = Set(storedRecord.attachments.map(\.id))
            for attachment in medicalRecords[index].attachments where !retainedIDs.contains(attachment.id) {
                attachmentStore.delete(attachment)
            }
            medicalRecords[index] = storedRecord
            isUpdate = true
        } else {
            medicalRecords.append(storedRecord)
            isUpdate = false
        }
        medicalRecords = HealthRecordSynchronizer.synchronizeInpatientDailyRecords(
            in: medicalRecords,
            for: storedRecord
        )
        let synchronization = HealthRecordSynchronizer.synchronizeHospitalProfiles(
            medicalRecords: medicalRecords,
            hospitalProfiles: hospitalProfiles,
            recordIDs: [storedRecord.id]
        )
        medicalRecords = synchronization.medicalRecords
        hospitalProfiles = synchronization.hospitalProfiles
        DiagnosticLogger.shared.log(.data, "就医记录\(isUpdate ? "更新" : "新增") id=\(storedRecord.id)")
        didMutate()
    }

    private static func normalizedTags(in record: MedicalRecord) -> MedicalRecord {
        var result = record
        result.tags = AppTagSupport.normalize(record.tags)
        return result
    }

    func hospitalProfile(
        named name: String,
        type: MedicalInstitutionType? = nil
    ) -> HospitalProfile? {
        let key = HealthRecordSynchronizer.hospitalNameKey(name)
        return hospitalProfiles.first {
            guard HealthRecordSynchronizer.hospitalNameKey($0.name) == key else { return false }
            guard let type else { return true }
            return $0.supports(type)
        }
    }

    func hospitalProfileNameExists(_ name: String, excluding id: UUID? = nil) -> Bool {
        let key = HealthRecordSynchronizer.hospitalNameKey(name)
        guard !key.isEmpty else { return false }
        return hospitalProfiles.contains {
            $0.id != id && HealthRecordSynchronizer.hospitalNameKey($0.name) == key
        }
    }

    @discardableResult
    func upsertHospitalProfile(_ profile: HospitalProfile) -> Bool {
        var storedProfile = profile
        storedProfile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        storedProfile.normalizeClassification()
        guard !storedProfile.name.isEmpty,
              !hospitalProfileNameExists(storedProfile.name, excluding: storedProfile.id) else {
            DiagnosticLogger.shared.log(.data, "医院档案保存被拒绝（名称为空或重复） id=\(profile.id)", level: .warning)
            return false
        }

        let previousName: String?
        let isUpdate: Bool
        if let index = hospitalProfiles.firstIndex(where: { $0.id == storedProfile.id }) {
            previousName = hospitalProfiles[index].name
            storedProfile.createdAt = hospitalProfiles[index].createdAt
            storedProfile.updatedAt = Date()
            hospitalProfiles[index] = storedProfile
            isUpdate = true
        } else {
            previousName = nil
            storedProfile.createdAt = Date()
            storedProfile.updatedAt = storedProfile.createdAt
            hospitalProfiles.append(storedProfile)
            isUpdate = false
        }

        let namesToMatch = [previousName, storedProfile.name]
            .compactMap { $0 }
            .map(HealthRecordSynchronizer.hospitalNameKey)
        for index in medicalRecords.indices
        where namesToMatch.contains(HealthRecordSynchronizer.hospitalNameKey(medicalRecords[index].hospital)) {
            medicalRecords[index].hospital = storedProfile.name
            if storedProfile.supports(medicalRecords[index].institutionType),
               medicalRecords[index].institutionType == .hospital {
                medicalRecords[index].hospitalLevel = storedProfile.level
                medicalRecords[index].hospitalGrade = storedProfile.grade
                medicalRecords[index].hospitalCategory = storedProfile.category
            }
            medicalRecords[index].normalizeInstitutionClassification()
            medicalRecords[index].updatedAt = Date()
        }
        DiagnosticLogger.shared.log(.data, "医院档案\(isUpdate ? "更新" : "新增") id=\(storedProfile.id)")
        didMutate()
        return true
    }

    func deleteHospitalProfiles(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        hospitalProfiles.removeAll { ids.contains($0.id) }
        DiagnosticLogger.shared.log(.data, "医院档案删除 count=\(ids.count)")
        didMutate()
    }

    func deleteMedicalRecords(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var recordIDsToDelete = ids
        let childrenByParentID = Dictionary(
            grouping: medicalRecords.compactMap { record -> (UUID, UUID)? in
                record.parentRecordID.map { ($0, record.id) }
            },
            by: \.0
        ).mapValues { $0.map(\.1) }
        var pendingParentIDs = Array(ids)
        var nextParentIndex = 0
        while nextParentIndex < pendingParentIDs.count {
            let parentID = pendingParentIDs[nextParentIndex]
            nextParentIndex += 1
            for childID in childrenByParentID[parentID, default: []]
            where recordIDsToDelete.insert(childID).inserted {
                pendingParentIDs.append(childID)
            }
        }

        for record in medicalRecords where recordIDsToDelete.contains(record.id) {
            record.attachments.forEach(attachmentStore.delete)
        }
        medicalRecords.removeAll { recordIDsToDelete.contains($0.id) }
        DiagnosticLogger.shared.log(.data, "就医记录删除 requested=\(ids.count) total=\(recordIDsToDelete.count)")
        didMutate()
    }

    func importMedicalAttachment(from url: URL) throws -> FileAttachment {
        try attachmentStore.importFile(from: url)
    }

    func saveMedicalPhoto(
        data: Data,
        fileName: String,
        contentType: UTType
    ) throws -> FileAttachment {
        try attachmentStore.save(
            data: data,
            originalFileName: fileName,
            contentType: contentType
        )
    }

    // deleteUncommittedAttachment, renameAttachment, restoreAttachmentLocation, attachmentURL
    // are provided by the AttachmentManaging protocol extension.

    private func classificationFieldCount(in record: MedicalRecord) -> Int {
        (record.hospitalLevel == .unspecified ? 0 : 1)
            + (record.hospitalGrade == .unspecified ? 0 : 1)
            + (record.hospitalCategory == .unspecified ? 0 : 1)
    }

    private func didMutate() {
        mutationNotifier?.moduleStoreDidMutate()
    }
}

#endif
