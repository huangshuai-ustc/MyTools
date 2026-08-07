import Foundation
import Testing
@testable import MyTools

struct HealthRecordSynchronizerTests {
    @Test func disabledLoadSkipsSynchronizationAndReenablingCatchesUp() {
        var parent = Self.inpatientEpisode(fromDay: 1, throughDay: 3)
        parent.hospital = "测试医院"
        let records = [parent]

        let disabled = HealthRecordSynchronizer.synchronizeLoadedRecords(
            medicalRecords: records,
            hospitalProfiles: [],
            isEnabled: false
        )
        #expect(disabled.medicalRecords == records)
        #expect(disabled.hospitalProfiles.isEmpty)
        #expect(!disabled.didChange)

        let enabled = HealthRecordSynchronizer.synchronizeLoadedRecords(
            medicalRecords: disabled.medicalRecords,
            hospitalProfiles: disabled.hospitalProfiles,
            isEnabled: true
        )
        #expect(enabled.medicalRecords.filter { $0.isInpatientDailyRecord }.count == 3)
        #expect(enabled.hospitalProfiles.map { $0.name } == ["测试医院"])
        #expect(enabled.didChange)
    }

    @Test func shrinkingInpatientRangeRemovesOnlyEmptyOutOfRangeDays() throws {
        var parent = Self.inpatientEpisode(fromDay: 1, throughDay: 3)
        var records = HealthRecordSynchronizer.synchronizeInpatientDailyRecords(
            in: [parent],
            for: parent
        )
        let dayThree = Self.date(day: 3)
        let contentIndex = try #require(records.firstIndex {
            $0.isInpatientDailyRecord && MedicalRecord.normalizedDate($0.date) == dayThree
        })
        records[contentIndex].notes = "需要保留"

        parent.inpatientEndDate = Self.date(day: 1)
        records[0] = parent
        let synchronized = HealthRecordSynchronizer.synchronizeInpatientDailyRecords(
            in: records,
            for: parent
        )
        let dailyRecords = synchronized.filter { $0.isInpatientDailyRecord }

        #expect(dailyRecords.count == 2)
        #expect(dailyRecords.contains { MedicalRecord.normalizedDate($0.date) == Self.date(day: 1) })
        #expect(dailyRecords.contains { $0.notes == "需要保留" && $0.date == dayThree })
        #expect(!dailyRecords.contains { MedicalRecord.normalizedDate($0.date) == Self.date(day: 2) })
    }

    @Test func hospitalMatchingIgnoresWhitespaceCaseAndCharacterWidth() {
        #expect(
            HealthRecordSynchronizer.hospitalNameKey("  ＡＢＣ医院 \n")
                == HealthRecordSynchronizer.hospitalNameKey("abc医院")
        )

        var record = MedicalRecord()
        record.hospital = "  ＡＢＣ医院 "
        var profile = HospitalProfile()
        profile.name = "abc医院"

        let result = HealthRecordSynchronizer.synchronizeHospitalProfiles(
            medicalRecords: [record],
            hospitalProfiles: [profile]
        )

        #expect(result.hospitalProfiles.count == 1)
    }

    @Test func hospitalClassificationIsBackfilledIntoUnclassifiedRecord() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var record = MedicalRecord()
        record.hospital = "测试医院"
        var profile = HospitalProfile()
        profile.name = "测试医院"
        profile.level = .levelThree
        profile.grade = .classA
        profile.category = .general

        let result = HealthRecordSynchronizer.synchronizeHospitalProfiles(
            medicalRecords: [record],
            hospitalProfiles: [profile],
            now: now
        )
        let synchronizedRecord = try #require(result.medicalRecords.first)

        #expect(synchronizedRecord.hospitalLevel == .levelThree)
        #expect(synchronizedRecord.hospitalGrade == .classA)
        #expect(synchronizedRecord.hospitalCategory == .general)
        #expect(synchronizedRecord.updatedAt == now)
        #expect(result.didChange)
    }

    private static func inpatientEpisode(fromDay startDay: Int, throughDay endDay: Int) -> MedicalRecord {
        var record = MedicalRecord()
        record.visitType = .inpatient
        record.date = date(day: startDay)
        record.inpatientEndDate = date(day: endDay)
        return record
    }

    private static func date(day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
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
