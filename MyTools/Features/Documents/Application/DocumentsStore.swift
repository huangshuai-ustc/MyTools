#if MYTOOLS_FEATURE_DOCUMENTS
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DocumentsStore: ObservableObject, ModuleLifecycleParticipant, ModuleDataCleanupParticipant, AttachmentManaging {
    static let notificationIdentifierPrefix = "credential-expiry-"

    @Published private(set) var documents: [CredentialDocument]
    @Published private(set) var fieldTemplates: [CredentialFieldTemplate]
    @Published private(set) var knownTags: [String]

    let attachmentStore: AttachmentStore
    private let notificationScheduler: any LocalNotificationScheduling
    private var isModuleVisible: Bool
    private weak var mutationNotifier: (any VaultMutationNotifying)?

    init(
        documents: [CredentialDocument] = [],
        fieldTemplates: [CredentialFieldTemplate] = CredentialFieldTemplate.defaultTemplates,
        knownTags: [String] = [],
        attachmentStore: AttachmentStore,
        notificationScheduler: any LocalNotificationScheduling = DisabledLocalNotificationScheduler(),
        isModuleVisible: Bool = true
    ) {
        let normalizedDocuments = documents.map(Self.normalizedTags(in:))
        self.documents = normalizedDocuments
        self.fieldTemplates = Self.normalizedTemplates(fieldTemplates)
        self.knownTags = AppTagSupport.merged(knownTags, with: normalizedDocuments.flatMap(\.tags))
        self.attachmentStore = attachmentStore
        self.notificationScheduler = notificationScheduler
        self.isModuleVisible = isModuleVisible
        reconcileExpiryNotifications()
    }

    var observedModules: Set<ToolModule> { [.documents] }
    var cleanupModule: ToolModule { .documents }

    func attach(mutationNotifier: any VaultMutationNotifying) {
        self.mutationNotifier = mutationNotifier
    }

    func replace(
        documents: [CredentialDocument],
        fieldTemplates: [CredentialFieldTemplate]? = nil,
        knownTags: [String]? = nil
    ) {
        let normalizedDocuments = documents.map(Self.normalizedTags(in:))
        self.documents = normalizedDocuments
        if let fieldTemplates {
            self.fieldTemplates = Self.normalizedTemplates(fieldTemplates)
        }
        self.knownTags = AppTagSupport.merged(
            knownTags ?? self.knownTags,
            with: normalizedDocuments.flatMap(\.tags)
        )
        DiagnosticLogger.shared.log(.data, "证照数据替换 count=\(normalizedDocuments.count)")
        reconcileExpiryNotifications()
    }

    func fieldTemplate(for documentType: CredentialDocumentType) -> CredentialFieldTemplate {
        fieldTemplates.first(where: { $0.documentType == documentType })
            ?? CredentialFieldTemplate(documentType: documentType, fields: documentType.defaultFields)
    }

    func makeFields(for documentType: CredentialDocumentType) -> [CredentialField] {
        fieldTemplate(for: documentType).makeFields()
    }

    func upsertFieldTemplate(_ template: CredentialFieldTemplate) {
        let normalized = template.normalized()
        if let index = fieldTemplates.firstIndex(where: {
            $0.documentType == normalized.documentType
        }) {
            fieldTemplates[index] = normalized
        } else {
            fieldTemplates.append(normalized)
        }
        fieldTemplates = Self.normalizedTemplates(fieldTemplates)
        let changedAt = Date()
        documents = documents.map { document in
            guard document.type == normalized.documentType else { return document }
            var updated = document
            var didUpdate = false
            updated.fields = document.fields.map { field in
                guard let templateField = matchingTemplateField(for: field, in: normalized),
                      field.isSensitive != templateField.isSensitive else {
                    return field
                }
                var field = field
                field.isSensitive = templateField.isSensitive
                didUpdate = true
                return field
            }
            if didUpdate { updated.updatedAt = changedAt }
            return updated
        }
        didMutate()
    }

    func moduleDidChange(_ module: ToolModule, isEnabled: Bool) {
        guard module == .documents else { return }
        isModuleVisible = isEnabled
        reconcileExpiryNotifications(forceEnabled: isEnabled)
    }

    func scanRedundantData() -> [RedundantDataFinding] {
        var findings: [RedundantDataFinding] = []

        appendFinding(
            to: &findings,
            ruleID: "legacy-date-of-birth",
            title: "旧版基本信息中的出生日期",
            detail: "出生日期不再属于证照基本信息，清理时会保留为同名自定义字段。",
            items: documents.filter { $0.legacyDateOfBirth != nil }
                .map { redundantItem($0, fields: ["出生日期"]) }
        )

        appendFinding(
            to: &findings,
            ruleID: "non-custom-type-name",
            title: "非自定义证照的类型名称",
            detail: "只有自定义证照会使用类型名称。",
            items: documents.filter { $0.type != .other && !$0.customTypeName.isEmpty }
                .map { redundantItem($0, fields: ["类型名称"]) }
        )

        appendFinding(
            to: &findings,
            ruleID: "inapplicable-validity-dates",
            title: "与期限类型不匹配的日期",
            detail: "清除当前期限类型不会读取的有效期开始日或结束日。",
            items: documents.filter { !staleValidityFieldNames(in: $0).isEmpty }
                .map { redundantItem($0, fields: staleValidityFieldNames(in: $0)) }
        )

        appendFinding(
            to: &findings,
            ruleID: "unusable-expiry-reminder",
            title: "无到期日的提醒开关",
            detail: "没有可计算到期日的证照无法触发到期提醒。",
            items: documents.filter { $0.expiryReminder.isEnabled && $0.expirationDate() == nil }
                .map { redundantItem($0, fields: ["到期提醒"]) }
        )

        return findings
    }

    private func redundantItem(_ document: CredentialDocument, fields: [String]) -> RedundantDataItem {
        RedundantDataItem(
            id: document.id.uuidString,
            recordTitle: document.listDisplayTitle,
            fieldNames: fields
        )
    }

    func cleanupRedundantData() {
        for index in documents.indices {
            documents[index].migrateLegacyDateOfBirthToCustomField()
            if documents[index].type != .other {
                documents[index].customTypeName = ""
            }
            clearStaleValidityDates(in: &documents[index])
            if documents[index].expirationDate() == nil {
                documents[index].expiryReminder.isEnabled = false
            }
        }
        reconcileExpiryNotifications()
    }

    func upsert(_ document: CredentialDocument) {
        var stored = normalized(document)
        stored.updatedAt = Date()
        let isUpdate: Bool
        var removedAttachments: [FileAttachment] = []
        if let index = documents.firstIndex(where: { $0.id == stored.id }) {
            let retainedIDs = Set(stored.attachments.map(\.id))
            removedAttachments = documents[index].attachments
                .filter { !retainedIDs.contains($0.id) }
                .map(\.file)
            stored.createdAt = documents[index].createdAt
            documents[index] = stored
            isUpdate = true
        } else {
            stored.createdAt = stored.updatedAt
            documents.append(stored)
            isUpdate = false
        }
        DiagnosticLogger.shared.log(.data, "证照\(isUpdate ? "更新" : "新增") id=\(stored.id)")
        reconcileExpiryNotifications()
        didMutate(removing: removedAttachments)
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var deletionIDs = ids
        for id in ids {
            deletionIDs.formUnion(
                documents.lazy.filter { $0.parentDocumentID == id }.map(\.id)
            )
        }
        let removedAttachments = documents
            .filter { deletionIDs.contains($0.id) }
            .flatMap { $0.attachments.map(\.file) }
        documents.removeAll { deletionIDs.contains($0.id) }
        DiagnosticLogger.shared.log(.data, "证照删除 requested=\(ids.count) total=\(deletionIDs.count)")
        reconcileExpiryNotifications()
        didMutate(removing: removedAttachments)
    }

    func versionGroup(for document: CredentialDocument) -> [CredentialDocument] {
        let rootID = document.rootDocumentID
        return documents
            .filter { $0.id == rootID || $0.parentDocumentID == rootID }
            .sorted(by: CredentialDocument.versionDisplayPrecedes)
    }

    func importAttachment(from url: URL) throws -> FileAttachment {
        let attachment = try attachmentStore.importFile(from: url)
        guard attachment.contentType.conforms(to: .image)
                || attachment.contentType.conforms(to: .pdf) else {
            attachmentStore.delete(attachment)
            DiagnosticLogger.shared.log(.attachment, "证照附件导入被拒绝（不支持的文件类型） name=\(url.lastPathComponent)", level: .warning)
            throw AttachmentStoreError.invalidFile
        }
        return attachment
    }

    func savePhoto(data: Data, fileName: String, contentType: UTType) throws -> FileAttachment {
        guard contentType.conforms(to: .image) else {
            throw AttachmentStoreError.invalidFile
        }
        return try attachmentStore.save(
            data: data,
            originalFileName: fileName,
            contentType: contentType
        )
    }

    // deleteUncommittedAttachment, renameAttachment, restoreAttachmentLocation, attachmentURL
    // are provided by the AttachmentManaging protocol extension.

    func attachmentData(for attachment: FileAttachment) throws -> Data {
        try attachmentStore.data(for: attachment)
    }

    private func normalized(_ document: CredentialDocument) -> CredentialDocument {
        var result = document
        if result.parentDocumentID == result.id {
            result.parentDocumentID = nil
        }
        result.title = ""
        result.customTypeName = normalizedText(result.customTypeName)
        result.holderName = normalizedText(result.holderName)
        result.documentNumber = normalizedText(result.documentNumber).uppercased()
        result.issuingAuthority = normalizedText(result.issuingAuthority)
        result.note = result.note.trimmingCharacters(in: .whitespacesAndNewlines)
        result.tags = normalizedTags(result.tags)
        knownTags = AppTagSupport.merged(knownTags, with: result.tags)
        result.fields = result.fields.compactMap { field in
            var field = field
            field.label = normalizedText(field.label)
            field.value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return field.label.isEmpty ? nil : field
        }
        result.migrateLegacyDateOfBirthToCustomField()
        normalizeValidity(in: &result)
        result.expiryReminder.normalize()
        if result.expirationDate() == nil {
            result.expiryReminder.isEnabled = false
        }
        return result
    }

    private func normalizeValidity(in document: inout CredentialDocument) {
        if CredentialValidityKind.isAlwaysPermanent(for: document.type) {
            document.validity = CredentialValidity(kind: .permanent)
            return
        }

        if document.validity.kind == .dateRange,
           let startDate = document.issuedAt ?? document.validity.startDate,
           let endDate = document.validity.endDate,
           let term = CredentialValidityKind.fixedTerm(
               for: document.type,
               from: startDate,
               to: endDate
           ) {
            document.issuedAt = document.issuedAt ?? startDate
            document.validity.kind = term
        } else if document.validity.kind.durationYears != nil,
                  !CredentialValidityKind.options(for: document.type).contains(document.validity.kind) {
            let endDate = document.expirationDate()
            document.validity = CredentialValidity(
                kind: .dateRange,
                startDate: document.issuedAt,
                endDate: endDate
            )
        } else if document.validity.kind == .dateRange {
            document.validity.startDate = document.issuedAt ?? document.validity.startDate
        }
        document.validity.normalize()
    }

    private func staleValidityFieldNames(in document: CredentialDocument) -> [String] {
        let start = document.validity.startDate == nil ? nil : "有效期开始日"
        let end = document.validity.endDate == nil ? nil : "有效期结束日"
        switch document.validity.kind {
        case .dateRange:
            return []
        case .permanent:
            return [document.type == .identityCard ? start : nil, end].compactMap { $0 }
        case .unspecified, .fiveYears, .sixYears, .tenYears, .twentyYears:
            return [start, end].compactMap { $0 }
        }
    }

    private func clearStaleValidityDates(in document: inout CredentialDocument) {
        switch document.validity.kind {
        case .dateRange:
            break
        case .permanent:
            if document.type == .identityCard {
                document.validity.startDate = nil
            }
            document.validity.endDate = nil
        case .unspecified, .fiveYears, .sixYears, .tenYears, .twentyYears:
            document.validity.startDate = nil
            document.validity.endDate = nil
        }
    }

    private func normalizedText(_ value: String) -> String {
        AppTagSupport.trimmed(value)
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        AppTagSupport.normalize(tags)
    }

    private static func normalizedTags(in document: CredentialDocument) -> CredentialDocument {
        var result = document
        result.tags = AppTagSupport.normalize(document.tags)
        return result
    }

    private static func normalizedTemplates(
        _ templates: [CredentialFieldTemplate]
    ) -> [CredentialFieldTemplate] {
        var byType = Dictionary(uniqueKeysWithValues: templates.map {
            ($0.documentType, $0.normalized())
        })
        for fallback in CredentialFieldTemplate.defaultTemplates
        where byType[fallback.documentType] == nil {
            byType[fallback.documentType] = fallback
        }
        return CredentialDocumentType.allCases.compactMap { byType[$0] }
    }

    private func matchingTemplateField(
        for field: CredentialField,
        in template: CredentialFieldTemplate
    ) -> CredentialField? {
        FieldTemplateMatching.matchingField(for: field, in: template.fields)
    }

    private func reconcileExpiryNotifications(forceEnabled: Bool? = nil, now: Date = Date()) {
        let enabled = forceEnabled ?? isModuleVisible
        let requests = enabled ? documents.compactMap { notification(for: $0, now: now) } : []
        notificationScheduler.replaceScheduledNotifications(
            requests,
            identifierPrefix: Self.notificationIdentifierPrefix
        )
    }

    private func notification(
        for document: CredentialDocument,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ScheduledLocalNotification? {
        guard document.versionStatus == .normal,
              document.expiryReminder.isEnabled,
              let endDate = document.expirationDate(calendar: calendar) else { return nil }
        let expiryDay = calendar.startOfDay(for: endDate)
        guard let reminderDay = calendar.date(
            byAdding: .day,
            value: -document.expiryReminder.daysBefore,
            to: expiryDay
        ),
        let scheduledFireDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: reminderDay),
        let expiryFireDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: expiryDay),
        let fireDate = Self.reminderFireDate(
            scheduled: scheduledFireDate,
            expiry: expiryFireDate,
            now: now,
            calendar: calendar
        ) else { return nil }
        return ScheduledLocalNotification(
            identifier: Self.notificationIdentifierPrefix + document.id.uuidString.lowercased(),
            title: "证照到期提醒",
            // 锁屏可见，正文不含持有人姓名（AUDIT-069）。
            body: "\(document.typeTitle)将于\(AppDateFormatter.string(from: endDate))到期。",
            fireDate: fireDate
        )
    }

    /// 已进入提前提醒窗口时，改在下一个 9:00 提醒，最晚到期当天（AUDIT-070）。
    static func reminderFireDate(
        scheduled: Date,
        expiry: Date,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        if scheduled > now { return scheduled }
        guard expiry > now,
              let next = calendar.nextDate(
                  after: now,
                  matching: DateComponents(hour: 9, minute: 0, second: 0),
                  matchingPolicy: .nextTime
              ) else { return nil }
        return min(next, expiry)
    }

    private func didMutate(removing attachments: [FileAttachment] = []) {
        mutationNotifier?.moduleStoreDidMutate()
        // Files go only after the Vault no longer referencing them is on disk
        // (AUDIT-017). A store without a Vault behind it deletes immediately.
        if let mutationNotifier {
            mutationNotifier.scheduleAttachmentRemovalAfterPersistence(attachments)
        } else {
            attachments.forEach(attachmentStore.delete)
        }
    }

}

#endif
