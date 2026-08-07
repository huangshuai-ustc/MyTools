import Foundation

enum MedicalCostInputSource: Sendable {
    case insurance
    case selfPay
}

struct MedicalRecordDraftInput {
    var record: MedicalRecord
    let associatedRecord: MedicalRecord?
    let existingRecords: [MedicalRecord]
    let tagsText: String
    let costInputSource: MedicalCostInputSource
    let insuranceCostText: String
    let selfPayCostText: String
    let updatedAt: Date
}

enum MedicalRecordValidationError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

enum MedicalCostAllocation {
    static func amount(from text: String, notExceeding totalCost: Decimal) -> Decimal? {
        guard let value = DecimalTextParser.optionalExpression(from: text),
              value >= 0,
              value <= totalCost else { return nil }
        return value
    }

    static func complementaryText(
        for text: String,
        totalCost: Decimal
    ) -> String? {
        guard let value = amount(from: text, notExceeding: totalCost) else { return nil }
        return NSDecimalNumber(decimal: totalCost - value).stringValue
    }

    static func allocation(
        totalCost: Decimal,
        paymentMethod: MedicalPaymentMethod,
        inputSource: MedicalCostInputSource,
        insuranceCostText: String,
        selfPayCostText: String
    ) -> Result<MedicalCostSummary, MedicalRecordValidationError> {
        switch paymentMethod {
        case .selfPay:
            return .success(MedicalCostSummary(
                totalCost: totalCost,
                insuranceCost: 0,
                selfPayCost: totalCost
            ))
        case .medicalInsurance:
            return .success(MedicalCostSummary(
                totalCost: totalCost,
                insuranceCost: totalCost,
                selfPayCost: 0
            ))
        case .medicalInsuranceThenSelfPay:
            switch inputSource {
            case .insurance:
                guard let value = amount(
                    from: insuranceCostText,
                    notExceeding: totalCost
                ) else {
                    return .failure(.invalid(
                        "医保支付仅支持数字、加减乘除和括号，且不能超过本次费用。"
                    ))
                }
                return .success(MedicalCostSummary(
                    totalCost: totalCost,
                    insuranceCost: value,
                    selfPayCost: totalCost - value
                ))
            case .selfPay:
                guard let value = amount(
                    from: selfPayCostText,
                    notExceeding: totalCost
                ) else {
                    return .failure(.invalid(
                        "自费仅支持数字、加减乘除和括号，且不能超过本次费用。"
                    ))
                }
                return .success(MedicalCostSummary(
                    totalCost: totalCost,
                    insuranceCost: totalCost - value,
                    selfPayCost: value
                ))
            }
        }
    }
}

enum MedicalRecordDraftValidator {
    static func validatedRecord(
        from input: MedicalRecordDraftInput
    ) -> Result<MedicalRecord, MedicalRecordValidationError> {
        var record = input.record
        record.normalizeInstitutionClassification()
        record.hospital = trimmed(record.hospital)
        record.department = trimmed(record.department)
        record.chiefComplaint = trimmed(record.chiefComplaint)
        record.diagnosis = trimmed(record.diagnosis)
        record.treatment = trimmed(record.treatment)
        if !record.isInpatient {
            record.inpatientEndDate = nil
        }

        let normalizedDate = MedicalRecord.normalizedDate(record.date)
        if record.isPharmacyPurchase {
            guard !record.hospital.isEmpty, !record.expenseItems.isEmpty else {
                return .failure(.invalid("请填写药房并至少添加一项药品。"))
            }
            record.department = ""
            record.doctor = ""
            record.diagnosis = ""
            record.treatment = ""
        } else if record.isPhysicalExam {
            guard !record.hospital.isEmpty else {
                return .failure(.invalid("请填写体检机构。"))
            }
            var details = record.physicalExamDetails ?? PhysicalExamDetails()
            details.packageName = trimmed(details.packageName)
            details.completedItems = trimmed(details.completedItems)
            details.findings = details.findings.map { finding in
                var finding = finding
                finding.item = trimmed(finding.item)
                finding.result = trimmed(finding.result)
                finding.recommendation = trimmed(finding.recommendation)
                return finding
            }
            record.physicalExamDetails = details
            record.department = ""
            record.doctor = ""
            record.chiefComplaint = ""
        } else if record.isInpatient {
            guard !record.hospital.isEmpty else {
                return .failure(.invalid("请填写医院。"))
            }
            if record.hasAssociatedRecord {
                record.inpatientEndDate = nil
            } else {
                let endDate = MedicalRecord.normalizedDate(
                    record.inpatientEndDate ?? record.date
                )
                guard endDate >= normalizedDate else {
                    return .failure(.invalid("出院日期不能早于入院日期。"))
                }
                record.inpatientEndDate = endDate
            }
        } else {
            guard !record.hospital.isEmpty,
                  !record.department.isEmpty,
                  !record.chiefComplaint.isEmpty,
                  !record.diagnosis.isEmpty else {
                return .failure(.invalid("医院、科室、主诉和初步诊断为必填项。"))
            }
        }

        if record.hasAssociatedRecord {
            guard let associatedRecord = input.associatedRecord else {
                return .failure(.invalid("关联的原就诊记录已不存在，无法保存这条记录。"))
            }
            guard normalizedDate >= MedicalRecord.normalizedDate(associatedRecord.date) else {
                let message: String
                if record.isPharmacyPurchase {
                    message = "购药日期不能早于关联就诊日期。"
                } else if record.isInpatient {
                    message = "住院日记录日期不能早于入院日期。"
                } else {
                    message = "复诊日期不能早于原就诊日期。"
                }
                return .failure(.invalid(message))
            }
            if record.isInpatient,
               let inpatientEndDate = associatedRecord.inpatientEndDate,
               normalizedDate > MedicalRecord.normalizedDate(inpatientEndDate) {
                return .failure(.invalid("住院日记录日期不能晚于出院日期。"))
            }
            if record.isInpatientDailyRecord,
               let parentRecordID = record.parentRecordID,
               input.existingRecords.contains(where: { other in
                   other.id != record.id
                       && other.parentRecordID == parentRecordID
                       && other.isInpatientDailyRecord
                       && MedicalRecord.normalizedDate(other.date) == normalizedDate
               }) {
                return .failure(.invalid("该日期已经存在住院日记录，请选择其他日期。"))
            }
        }

        let allocation = MedicalCostAllocation.allocation(
            totalCost: record.expenseItemsTotal,
            paymentMethod: record.paymentMethod,
            inputSource: input.costInputSource,
            insuranceCostText: input.insuranceCostText,
            selfPayCostText: input.selfPayCostText
        )
        guard case .success(let costs) = allocation else {
            if case .failure(let error) = allocation { return .failure(error) }
            return .failure(.invalid("无法计算费用。"))
        }

        record.date = normalizedDate
        record.totalCost = costs.totalCost
        record.insuranceCost = costs.insuranceCost
        record.selfPayCost = costs.selfPayCost
        record.tags = parsedTags(input.tagsText)
        record.updatedAt = input.updatedAt
        return .success(record)
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parsedTags(_ text: String) -> [String] {
        var result: [String] = []
        for rawTag in text.split(whereSeparator: { ",，、".contains($0) }) {
            let tag = trimmed(String(rawTag))
            if !tag.isEmpty, !result.contains(tag) { result.append(tag) }
        }
        return result
    }
}
