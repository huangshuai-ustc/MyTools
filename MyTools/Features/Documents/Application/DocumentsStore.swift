#if MYTOOLS_FEATURE_DOCUMENTS
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DocumentsStore: ObservableObject, ModuleLifecycleParticipant, ModuleDataCleanupParticipant {
    static let notificationIdentifierPrefix = "credential-expiry-"

    @Published private(set) var documents: [CredentialDocument]

    private let attachmentStore: AttachmentStore
    private let notificationScheduler: any LocalNotificationScheduling
    private weak var moduleSettings: ToolModuleSettings?
    private weak var mutationNotifier: (any VaultMutationNotifying)?

    init(
        documents: [CredentialDocument] = [],
        attachmentStore: AttachmentStore,
        notificationScheduler: any LocalNotificationScheduling = DisabledLocalNotificationScheduler(),
        moduleSettings: ToolModuleSettings? = nil
    ) {
        self.documents = documents
        self.attachmentStore = attachmentStore
        self.notificationScheduler = notificationScheduler
        self.moduleSettings = moduleSettings
        reconcileExpiryNotifications()
    }

    var observedModules: Set<ToolModule> { [.documents] }
    var cleanupModule: ToolModule { .documents }

    func attach(mutationNotifier: any VaultMutationNotifying) {
        self.mutationNotifier = mutationNotifier
    }

    func replace(documents: [CredentialDocument]) {
        self.documents = documents
        reconcileExpiryNotifications()
    }

    func moduleDidChange(_ module: ToolModule, isEnabled: Bool) {
        guard module == .documents else { return }
        reconcileExpiryNotifications(forceEnabled: isEnabled)
    }

    func scanRedundantData() -> [RedundantDataFinding] {
        var findings: [RedundantDataFinding] = []

        let birthDateRecords = documents.filter { $0.legacyDateOfBirth != nil }.count
        appendFinding(
            to: &findings,
            ruleID: "legacy-date-of-birth",
            title: "旧版基本信息中的出生日期",
            detail: "出生日期不再属于证照基本信息，清理时会保留为同名自定义字段。",
            recordCount: birthDateRecords,
            fieldCount: birthDateRecords
        )

        let customTypeRecords = documents.filter {
            $0.type != .other && !$0.customTypeName.isEmpty
        }.count
        appendFinding(
            to: &findings,
            ruleID: "non-custom-type-name",
            title: "非自定义证照的类型名称",
            detail: "只有自定义证照会使用类型名称。",
            recordCount: customTypeRecords,
            fieldCount: customTypeRecords
        )

        let staleValidityRecords = documents.filter { staleValidityFieldCount(in: $0) > 0 }
        appendFinding(
            to: &findings,
            ruleID: "inapplicable-validity-dates",
            title: "与期限类型不匹配的日期",
            detail: "清除当前期限类型不会读取的有效期开始日或结束日。",
            recordCount: staleValidityRecords.count,
            fieldCount: staleValidityRecords.reduce(0) { $0 + staleValidityFieldCount(in: $1) }
        )

        let reminderRecords = documents.filter {
            $0.expiryReminder.isEnabled && $0.expirationDate() == nil
        }.count
        appendFinding(
            to: &findings,
            ruleID: "unusable-expiry-reminder",
            title: "无到期日的提醒开关",
            detail: "没有可计算到期日的证照无法触发到期提醒。",
            recordCount: reminderRecords,
            fieldCount: reminderRecords
        )

        return findings
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
        if let index = documents.firstIndex(where: { $0.id == stored.id }) {
            let retainedIDs = Set(stored.attachments.map(\.id))
            for attachment in documents[index].attachments where !retainedIDs.contains(attachment.id) {
                attachmentStore.delete(attachment.file)
            }
            stored.createdAt = documents[index].createdAt
            documents[index] = stored
        } else {
            stored.createdAt = stored.updatedAt
            documents.append(stored)
        }
        reconcileExpiryNotifications()
        didMutate()
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var deletionIDs = ids
        for id in ids {
            deletionIDs.formUnion(
                documents.lazy.filter { $0.parentDocumentID == id }.map(\.id)
            )
        }
        for document in documents where deletionIDs.contains(document.id) {
            document.attachments.forEach { attachmentStore.delete($0.file) }
        }
        documents.removeAll { deletionIDs.contains($0.id) }
        reconcileExpiryNotifications()
        didMutate()
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

    func deleteUncommittedAttachment(_ attachment: FileAttachment) {
        attachmentStore.delete(attachment)
    }

    func renameAttachment(_ attachment: FileAttachment, to fileName: String) throws -> FileAttachment {
        try attachmentStore.rename(attachment, to: fileName)
    }

    func restoreAttachmentLocation(
        _ attachment: FileAttachment,
        to original: FileAttachment
    ) throws {
        try attachmentStore.restoreLocation(of: attachment, to: original)
    }

    func attachmentURL(for attachment: FileAttachment) -> URL {
        attachmentStore.url(for: attachment)
    }

    func attachmentData(for attachment: FileAttachment) throws -> Data {
        try attachmentStore.data(for: attachment)
    }

    private var isModuleVisible: Bool {
        moduleSettings?.isVisible(.documents) ?? true
    }

    private func normalized(_ document: CredentialDocument) -> CredentialDocument {
        var result = document
        if result.parentDocumentID == result.id {
            result.parentDocumentID = nil
        }
        result.title = normalizedText(result.title)
        result.customTypeName = normalizedText(result.customTypeName)
        result.holderName = normalizedText(result.holderName)
        result.documentNumber = normalizedText(result.documentNumber).uppercased()
        result.issuingAuthority = normalizedText(result.issuingAuthority)
        result.note = result.note.trimmingCharacters(in: .whitespacesAndNewlines)
        result.tags = normalizedTags(result.tags)
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
        if document.type == .identityCard {
            let startDate = document.issuedAt ?? document.validity.startDate
            if document.issuedAt == nil {
                document.issuedAt = startDate
            }
            if document.validity.kind == .dateRange,
               let startDate,
               let endDate = document.validity.endDate,
               let term = CredentialValidityKind.identityCardTerm(
                   from: startDate,
                   to: endDate
               ) {
                document.validity.kind = term
            }
        } else if document.validity.kind.durationYears != nil {
            let endDate = document.expirationDate()
            document.validity = CredentialValidity(
                kind: .dateRange,
                startDate: document.issuedAt,
                endDate: endDate
            )
        }
        document.validity.normalize()
    }

    private func staleValidityFieldCount(in document: CredentialDocument) -> Int {
        switch document.validity.kind {
        case .dateRange:
            return 0
        case .permanent:
            return (document.type == .identityCard && document.validity.startDate != nil ? 1 : 0)
                + (document.validity.endDate != nil ? 1 : 0)
        case .unspecified, .fiveYears, .tenYears, .twentyYears:
            return (document.validity.startDate != nil ? 1 : 0)
                + (document.validity.endDate != nil ? 1 : 0)
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
        case .unspecified, .fiveYears, .tenYears, .twentyYears:
            document.validity.startDate = nil
            document.validity.endDate = nil
        }
    }

    private func appendFinding(
        to findings: inout [RedundantDataFinding],
        ruleID: String,
        title: String,
        detail: String,
        recordCount: Int,
        fieldCount: Int
    ) {
        guard fieldCount > 0 else { return }
        findings.append(RedundantDataFinding(
            ruleID: ruleID,
            module: .documents,
            title: title,
            detail: detail,
            affectedRecordCount: recordCount,
            affectedFieldCount: fieldCount
        ))
    }

    private func normalizedText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        var keys = Set<String>()
        return tags.compactMap { value in
            let tag = normalizedText(value)
            guard !tag.isEmpty else { return nil }
            let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return keys.insert(key).inserted ? tag : nil
        }
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
        let fireDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: reminderDay),
        fireDate > now else { return nil }
        return ScheduledLocalNotification(
            identifier: Self.notificationIdentifierPrefix + document.id.uuidString.lowercased(),
            title: "证照到期提醒",
            body: "\(document.displayTitle)将于\(AppDateFormatter.string(from: endDate))到期。",
            fireDate: fireDate
        )
    }

    private func didMutate() {
        mutationNotifier?.moduleStoreDidMutate()
    }

}

#endif
