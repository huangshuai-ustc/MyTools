import Foundation
import Testing
@testable import MyTools

struct MedicalRecordsPresentationTests {
    @Test func matchingLinkedRecordKeepsItsParentEpisodeVisible() {
        let parent = record(hospital: "Example Hospital", day: 1)
        var followUp = MedicalRecord(followUpTo: parent, date: date(2))
        followUp.diagnosis = "Target diagnosis"
        let presentation = makePresentation(
            records: [parent, followUp],
            query: "target"
        )

        #expect(presentation.visitGroups.count == 1)
        #expect(presentation.visitGroups.first?.originalVisit.id == parent.id)
        #expect(presentation.visitGroups.first?.followUps.map(\.id) == [followUp.id])
    }

    @Test func episodeGroupsLinkedRecordsAndAggregatesAllCosts() {
        var parent = record(hospital: "Example Hospital", day: 1)
        parent.totalCost = 100
        parent.insuranceCost = 60
        parent.selfPayCost = 40
        var followUp = MedicalRecord(followUpTo: parent, date: date(2))
        followUp.totalCost = 20
        followUp.selfPayCost = 20
        var pharmacy = MedicalRecord(pharmacyPurchaseFor: parent, date: date(3))
        pharmacy.totalCost = 30
        pharmacy.selfPayCost = 30

        let group = makePresentation(records: [pharmacy, followUp, parent])
            .visitGroups.first

        #expect(group?.followUps.map(\.id) == [followUp.id])
        #expect(group?.pharmacyPurchases.map(\.id) == [pharmacy.id])
        #expect(group?.costSummary.totalCost == 150)
        #expect(group?.costSummary.insuranceCost == 60)
        #expect(group?.costSummary.selfPayCost == 90)
    }

    @Test func orphanedLinkedRecordRemainsVisibleAsARoot() {
        var orphan = record(hospital: "Orphan Clinic", day: 3)
        orphan.parentRecordID = UUID()

        let groups = makePresentation(records: [orphan]).visitGroups

        #expect(groups.count == 1)
        #expect(groups.first?.originalVisit.id == orphan.id)
    }

    @Test func overviewYearFilterIncludesPharmacyCostButNotPharmacyVisit() {
        var visit = record(hospital: " Hospital A ", day: 1, year: 2025)
        visit.totalCost = 100
        visit.insuranceCost = 70
        visit.selfPayCost = 30
        var secondVisit = record(hospital: "Hospital A", day: 2, year: 2025)
        secondVisit.totalCost = 50
        secondVisit.insuranceCost = 10
        secondVisit.selfPayCost = 40
        var pharmacy = record(hospital: "Pharmacy", day: 3, year: 2025)
        pharmacy.visitType = .pharmacyPurchase
        pharmacy.totalCost = 50
        pharmacy.selfPayCost = 50
        var otherYear = record(hospital: "Hospital B", day: 1, year: 2026)
        otherYear.totalCost = 1_000

        let overview = makePresentation(
            records: [visit, secondVisit, pharmacy, otherYear],
            selectedYear: 2025
        ).overview

        #expect(overview.hospitalCount == 1)
        #expect(overview.visitCount == 2)
        #expect(overview.total == 200)
        #expect(overview.insurance == 80)
        #expect(overview.selfPay == 120)
        #expect(overview.insuranceRatio == Decimal(string: "0.4"))
        #expect(overview.selfPayRatio == Decimal(string: "0.6"))
    }

    @Test(arguments: ["needle item", "needle result", "needle tag", "三级"])
    func searchCoversExpensePhysicalExamTagAndClassification(_ query: String) {
        var record = record(hospital: "Example", day: 1)
        record.hospitalLevel = .levelThree
        record.tags = ["needle tag"]
        record.expenseItems = [MedicalExpenseItem(name: "needle item")]
        record.physicalExamDetails = PhysicalExamDetails(
            findings: [PhysicalExamFinding(result: "needle result")]
        )

        #expect(makePresentation(records: [record], query: query).visitGroups.count == 1)
    }

    @Test func yearsAndTagsAreUniqueAndSorted() {
        var older = record(hospital: "A", day: 1, year: 2024)
        older.tags = ["Zulu", "Alpha"]
        var newer = record(hospital: "B", day: 1, year: 2025)
        newer.tags = ["Alpha"]
        let presentation = makePresentation(
            records: [older, newer],
            currentDate: date(1, year: 2026)
        )

        #expect(presentation.availableYears == [2026, 2025, 2024])
        #expect(presentation.allTags == ["Alpha", "Zulu"])
        #expect(presentation.yearGroups.map(\.year) == [2025, 2024])
    }

    private func makePresentation(
        records: [MedicalRecord],
        query: String = "",
        selectedYear: Int? = nil,
        currentDate: Date? = nil
    ) -> MedicalRecordsPresentation {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return MedicalRecordsPresentation(
            records: records,
            query: query,
            selectedYear: selectedYear,
            calendar: calendar,
            currentDate: currentDate ?? date(1, year: 2026)
        )
    }

    private func record(
        hospital: String,
        day: Int,
        year: Int = 2026
    ) -> MedicalRecord {
        var record = MedicalRecord()
        record.hospital = hospital
        record.date = date(day, year: year)
        return record
    }

    private func date(_ day: Int, year: Int = 2026) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(
            year: year,
            month: 8,
            day: day,
            hour: 12
        ))!
    }
}
