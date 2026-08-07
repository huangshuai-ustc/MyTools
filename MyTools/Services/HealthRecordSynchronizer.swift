import Foundation

struct HealthRecordSynchronizationResult {
    var medicalRecords: [MedicalRecord]
    var hospitalProfiles: [HospitalProfile]
    var didChange: Bool
}

enum HealthRecordSynchronizer {
    static func synchronizeLoadedRecords(
        medicalRecords: [MedicalRecord],
        hospitalProfiles: [HospitalProfile],
        isEnabled: Bool,
        now: Date = Date()
    ) -> HealthRecordSynchronizationResult {
        guard isEnabled else {
            return HealthRecordSynchronizationResult(
                medicalRecords: medicalRecords,
                hospitalProfiles: hospitalProfiles,
                didChange: false
            )
        }

        var synchronizedRecords = medicalRecords
        let inpatientEpisodes = synchronizedRecords.filter(\.isInpatientEpisode)
        for parent in inpatientEpisodes {
            synchronizedRecords = synchronizeInpatientDailyRecords(
                in: synchronizedRecords,
                for: parent
            )
        }
        return synchronizeHospitalProfiles(
            medicalRecords: synchronizedRecords,
            hospitalProfiles: hospitalProfiles,
            originalMedicalRecords: medicalRecords,
            now: now
        )
    }

    static func synchronizeInpatientDailyRecords(
        in medicalRecords: [MedicalRecord],
        for parent: MedicalRecord
    ) -> [MedicalRecord] {
        guard parent.isInpatientEpisode else { return medicalRecords }

        let startDate = MedicalRecord.normalizedDate(parent.date)
        let requestedEndDate = MedicalRecord.normalizedDate(parent.inpatientEndDate ?? parent.date)
        let endDate = max(startDate, requestedEndDate)
        var synchronizedRecords = medicalRecords.filter { record in
            guard record.parentRecordID == parent.id,
                  record.isInpatientDailyRecord,
                  !record.hasInpatientDailyContent else { return true }
            let date = MedicalRecord.normalizedDate(record.date)
            return date >= startDate && date <= endDate
        }

        let existingDates = Set(
            synchronizedRecords
                .filter { $0.parentRecordID == parent.id && $0.isInpatientDailyRecord }
                .map { MedicalRecord.normalizedDate($0.date) }
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        var currentDate = startDate
        while currentDate <= endDate {
            if !existingDates.contains(currentDate) {
                synchronizedRecords.append(MedicalRecord(inpatientDayFor: parent, date: currentDate))
            }
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) else {
                break
            }
            currentDate = MedicalRecord.normalizedDate(nextDate)
        }
        return synchronizedRecords
    }

    static func synchronizeHospitalProfiles(
        medicalRecords: [MedicalRecord],
        hospitalProfiles: [HospitalProfile],
        recordIDs: Set<UUID>? = nil,
        now: Date = Date()
    ) -> HealthRecordSynchronizationResult {
        synchronizeHospitalProfiles(
            medicalRecords: medicalRecords,
            hospitalProfiles: hospitalProfiles,
            originalMedicalRecords: medicalRecords,
            recordIDs: recordIDs,
            now: now
        )
    }

    static func hospitalNameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "zh_CN")
        )
    }

    private static func synchronizeHospitalProfiles(
        medicalRecords: [MedicalRecord],
        hospitalProfiles: [HospitalProfile],
        originalMedicalRecords: [MedicalRecord],
        recordIDs: Set<UUID>? = nil,
        now: Date
    ) -> HealthRecordSynchronizationResult {
        var records = medicalRecords
        var profiles = hospitalProfiles

        for index in records.indices where recordIDs?.contains(records[index].id) ?? true {
            records[index].normalizeInstitutionClassification()
            let key = hospitalNameKey(records[index].hospital)
            guard !key.isEmpty else { continue }

            guard let profileIndex = profiles.firstIndex(where: {
                hospitalNameKey($0.name) == key
            }) else {
                profiles.append(HospitalProfile(record: records[index]))
                continue
            }

            var profileChanged = false
            var recordChanged = false
            let institutionType = records[index].institutionType
            if !profiles[profileIndex].supports(institutionType) {
                profiles[profileIndex].institutionTypes.insert(institutionType)
                profileChanged = true
            }

            if institutionType == .hospital {
                synchronizeClassification(
                    recordValue: &records[index].hospitalLevel,
                    profileValue: &profiles[profileIndex].level,
                    unspecified: .unspecified,
                    recordChanged: &recordChanged,
                    profileChanged: &profileChanged
                )
                synchronizeClassification(
                    recordValue: &records[index].hospitalGrade,
                    profileValue: &profiles[profileIndex].grade,
                    unspecified: .unspecified,
                    recordChanged: &recordChanged,
                    profileChanged: &profileChanged
                )
                synchronizeClassification(
                    recordValue: &records[index].hospitalCategory,
                    profileValue: &profiles[profileIndex].category,
                    unspecified: .unspecified,
                    recordChanged: &recordChanged,
                    profileChanged: &profileChanged
                )
            }

            let profileBeforeNormalization = profiles[profileIndex]
            profiles[profileIndex].normalizeClassification()
            if profiles[profileIndex] != profileBeforeNormalization {
                profileChanged = true
            }
            if profileChanged {
                profiles[profileIndex].updatedAt = now
            }
            if recordChanged {
                records[index].updatedAt = now
            }
        }

        return HealthRecordSynchronizationResult(
            medicalRecords: records,
            hospitalProfiles: profiles,
            didChange: records != originalMedicalRecords || profiles != hospitalProfiles
        )
    }

    private static func synchronizeClassification<Value: Equatable>(
        recordValue: inout Value,
        profileValue: inout Value,
        unspecified: Value,
        recordChanged: inout Bool,
        profileChanged: inout Bool
    ) {
        if recordValue != unspecified {
            if profileValue != recordValue {
                profileValue = recordValue
                profileChanged = true
            }
        } else if profileValue != unspecified {
            recordValue = profileValue
            recordChanged = true
        }
    }
}
