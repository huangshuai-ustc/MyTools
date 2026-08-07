import Foundation

struct MedicalYearGroup: Identifiable, Equatable {
    let year: Int
    let visitGroups: [MedicalVisitGroup]

    var id: Int { year }
}

struct MedicalOverviewSnapshot: Equatable {
    let hospitalCount: Int
    let visitCount: Int
    let total: Decimal
    let insurance: Decimal
    let selfPay: Decimal
    let insuranceRatio: Decimal
    let selfPayRatio: Decimal
}

struct MedicalVisitGroup: Identifiable, Equatable {
    let originalVisit: MedicalRecord
    let followUps: [MedicalRecord]
    let pharmacyPurchases: [MedicalRecord]
    let costSummary: MedicalCostSummary

    var id: UUID { originalVisit.id }
}

struct MedicalRecordsPresentation {
    let records: [MedicalRecord]
    let query: String
    let selectedTag: String
    let selectedYear: Int?
    let calendar: Calendar
    let currentDate: Date

    init(
        records: [MedicalRecord],
        query: String = "",
        selectedTag: String = "",
        selectedYear: Int? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        currentDate: Date = Date()
    ) {
        self.records = records
        self.query = query
        self.selectedTag = selectedTag
        self.selectedYear = selectedYear
        self.calendar = calendar
        self.currentDate = currentDate
    }

    var visitGroups: [MedicalVisitGroup] {
        let recordIDs = Set(records.map(\.id))
        let originalVisits = records
            .filter { record in
                guard let parentID = record.parentRecordID else { return true }
                return !recordIDs.contains(parentID)
            }
            .sorted { $0.date > $1.date }
        let linkedRecordsByParentID = Dictionary(
            grouping: records.compactMap { record -> (UUID, MedicalRecord)? in
                record.parentRecordID.map { ($0, record) }
            },
            by: \.0
        ).mapValues { values in
            values.map(\.1).sorted { $0.date < $1.date }
        }

        return originalVisits.compactMap { originalVisit in
            let linkedRecords = linkedRecordsByParentID[originalVisit.id, default: []]
            let matchingLinkedRecords = linkedRecords.filter(matchesFilters)
            guard matchesFilters(originalVisit) || !matchingLinkedRecords.isEmpty else {
                return nil
            }
            return MedicalVisitGroup(
                originalVisit: originalVisit,
                followUps: linkedRecords.filter { !$0.isPharmacyPurchase },
                pharmacyPurchases: linkedRecords.filter(\.isLinkedPharmacyPurchase),
                costSummary: linkedRecords.reduce(originalVisit.costSummary) {
                    $0 + $1.costSummary
                }
            )
        }
    }

    var yearGroups: [MedicalYearGroup] {
        Dictionary(grouping: visitGroups) {
            calendar.component(.year, from: $0.originalVisit.date)
        }
        .map { year, groups in
            MedicalYearGroup(
                year: year,
                visitGroups: groups.sorted {
                    $0.originalVisit.date > $1.originalVisit.date
                }
            )
        }
        .sorted { $0.year > $1.year }
    }

    var availableYears: [Int] {
        let currentYear = calendar.component(.year, from: currentDate)
        return Array(Set(
            records.map { calendar.component(.year, from: $0.date) } + [currentYear]
        )).sorted(by: >)
    }

    var allTags: [String] {
        Array(Set(records.flatMap(\.tags))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var overview: MedicalOverviewSnapshot {
        var total = Decimal.zero
        var insurance = Decimal.zero
        var selfPay = Decimal.zero
        var visitCount = 0
        var hospitals: Set<String> = []

        for record in records {
            if let selectedYear,
               calendar.component(.year, from: record.date) != selectedYear {
                continue
            }
            total += record.totalCost
            insurance += record.insuranceCost
            selfPay += record.selfPayCost
            guard !record.isPharmacyPurchase else { continue }
            visitCount += 1
            let hospital = record.hospital.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hospital.isEmpty { hospitals.insert(hospital) }
        }

        return MedicalOverviewSnapshot(
            hospitalCount: hospitals.count,
            visitCount: visitCount,
            total: total,
            insurance: insurance,
            selfPay: selfPay,
            insuranceRatio: Self.ratio(insurance, of: total),
            selfPayRatio: Self.ratio(selfPay, of: total)
        )
    }

    func matchesFilters(_ record: MedicalRecord) -> Bool {
        guard selectedTag.isEmpty || record.tags.contains(selectedTag) else {
            return false
        }
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return searchTerm.isEmpty
            || record.hospital.localizedCaseInsensitiveContains(searchTerm)
            || record.department.localizedCaseInsensitiveContains(searchTerm)
            || record.doctor.localizedCaseInsensitiveContains(searchTerm)
            || record.chiefComplaint.localizedCaseInsensitiveContains(searchTerm)
            || record.diagnosis.localizedCaseInsensitiveContains(searchTerm)
            || record.treatment.localizedCaseInsensitiveContains(searchTerm)
            || record.physicalExamDetails?.packageName
                .localizedCaseInsensitiveContains(searchTerm) == true
            || record.physicalExamDetails?.completedItems
                .localizedCaseInsensitiveContains(searchTerm) == true
            || record.physicalExamDetails?.findings.contains {
                $0.item.localizedCaseInsensitiveContains(searchTerm)
                    || $0.result.localizedCaseInsensitiveContains(searchTerm)
                    || $0.recommendation.localizedCaseInsensitiveContains(searchTerm)
            } == true
            || record.hospitalClassificationTitles.contains {
                $0.localizedCaseInsensitiveContains(searchTerm)
            }
            || record.tags.contains {
                $0.localizedCaseInsensitiveContains(searchTerm)
            }
            || record.expenseItems.contains {
                $0.name.localizedCaseInsensitiveContains(searchTerm)
                    || $0.unit.localizedCaseInsensitiveContains(searchTerm)
                    || $0.note.localizedCaseInsensitiveContains(searchTerm)
            }
            || record.attachments.contains {
                $0.fileName.localizedCaseInsensitiveContains(searchTerm)
                    || $0.kind.title.localizedCaseInsensitiveContains(searchTerm)
            }
    }

    private static func ratio(_ value: Decimal, of total: Decimal) -> Decimal {
        guard total > 0 else { return 0 }
        return NSDecimalNumber(decimal: value)
            .dividing(by: NSDecimalNumber(decimal: total))
            .decimalValue
    }
}
