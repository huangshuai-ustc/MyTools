import Foundation
import Testing
@testable import MyTools

struct MedicalRecordEditingTests {
    @Test func validatorNormalizesFieldsTagsAndMixedCosts() throws {
        var record = MedicalRecord()
        record.hospital = "  示例医院  "
        record.department = "  内科 "
        record.chiefComplaint = " 发热 "
        record.diagnosis = " 感冒 "
        record.paymentMethod = .medicalInsuranceThenSelfPay
        record.expenseItems = [MedicalExpenseItem(
            name: "检查",
            quantity: 1,
            unit: "次",
            amount: 100
        )]
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let validated = try MedicalRecordDraftValidator.validatedRecord(
            from: MedicalRecordDraftInput(
                record: record,
                associatedRecord: nil,
                existingRecords: [],
                tagsText: " 内科、复诊，内科 ",
                costInputSource: .insurance,
                insuranceCostText: "25+25",
                selfPayCostText: "",
                updatedAt: updatedAt
            )
        ).get()

        #expect(validated.hospital == "示例医院")
        #expect(validated.department == "内科")
        #expect(validated.totalCost == 100)
        #expect(validated.insuranceCost == 50)
        #expect(validated.selfPayCost == 50)
        #expect(validated.tags == ["内科", "复诊"])
        #expect(validated.updatedAt == updatedAt)
    }

    @Test func validatorRejectsDuplicateInpatientDay() {
        var parent = MedicalRecord()
        parent.visitType = .inpatient
        parent.hospital = "示例医院"
        parent.date = date(day: 1)
        parent.inpatientEndDate = date(day: 3)
        let existing = MedicalRecord(inpatientDayFor: parent, date: date(day: 2))
        var candidate = MedicalRecord(inpatientDayFor: parent, date: date(day: 2))
        candidate.id = UUID()

        let result = MedicalRecordDraftValidator.validatedRecord(from: MedicalRecordDraftInput(
            record: candidate,
            associatedRecord: parent,
            existingRecords: [parent, existing],
            tagsText: "",
            costInputSource: .insurance,
            insuranceCostText: "",
            selfPayCostText: "",
            updatedAt: Date()
        ))

        #expect(result == .failure(.invalid("该日期已经存在住院日记录，请选择其他日期。")))
    }

    @Test func attachmentSessionRollsBackRenameAndNewFilesExactlyOnce() {
        var original = FileAttachment()
        original.fileName = "原始.pdf"
        original.storedFileName = "original.pdf"
        var renamed = original
        renamed.fileName = "新名称.pdf"
        renamed.storedFileName = "renamed.pdf"
        var added = FileAttachment()
        added.fileName = "新增.jpg"
        added.storedFileName = "added.jpg"
        var session = AttachmentEditSession(originalAttachments: [original])
        session.trackRename(renamed)
        var deleted: [FileAttachment] = []
        var restored: [(FileAttachment, FileAttachment)] = []

        let failures = session.rollback(
            currentAttachments: [added],
            delete: { deleted.append($0) },
            restoreLocation: { restored.append(($0, $1)) }
        )
        _ = session.rollback(
            currentAttachments: [added],
            delete: { deleted.append($0) },
            restoreLocation: { restored.append(($0, $1)) }
        )

        #expect(failures.isEmpty)
        #expect(deleted == [added])
        #expect(restored.count == 1)
        #expect(restored.first?.0 == renamed)
        #expect(restored.first?.1 == original)
    }

    private func date(day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: day,
            hour: 12
        ))!
    }
}
