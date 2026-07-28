@preconcurrency import CloudKit
import Foundation

enum PresetSync {
    private static let recordType = "UserPreset"
    private static let payloadKey = "payload"
    private static let containerInfoKey = "FocelleCloudKitContainer"

    static func fetch() async throws -> [UserPreset] {
        let database = try database()
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var page = try await database.records(
            matching: query,
            desiredKeys: [payloadKey],
            resultsLimit: CKQueryOperation.maximumResults
        )
        var records = decode(page.matchResults)

        while let cursor = page.queryCursor {
            page = try await database.records(
                continuingMatchFrom: cursor,
                desiredKeys: [payloadKey],
                resultsLimit: CKQueryOperation.maximumResults
            )
            records += decode(page.matchResults)
        }
        return records
    }

    static func push(_ presets: [UserPreset]) async throws {
        // ponytail: whole-set sync is enough for a small preset library; use CKSyncEngine if write volume grows.
        let encoder = JSONEncoder()
        let records = try presets.map { preset in
            let record = CKRecord(
                recordType: recordType,
                recordID: CKRecord.ID(recordName: preset.id.uuidString)
            )
            record[payloadKey] = try encoder.encode(preset) as CKRecordValue
            return record
        }
        _ = try await database().modifyRecords(
            saving: records,
            deleting: [],
            savePolicy: .allKeys,
            atomically: false
        )
    }

    private static func database() throws -> CKDatabase {
        #if targetEnvironment(simulator)
            // ponytail: unsigned CI simulators cannot use CloudKit; verify sync on signed devices.
            throw PresetSyncError.iCloudNotConfigured
        #else
            // An empty container means this build was signed without the iCloud entitlement.
            // CKContainer(identifier:) traps there instead of throwing, so never construct one.
            guard
                let identifier = containerIdentifier(
                    Bundle.main.object(forInfoDictionaryKey: containerInfoKey) as? String
                )
            else {
                throw PresetSyncError.iCloudNotConfigured
            }
            return CKContainer(identifier: identifier).privateCloudDatabase
        #endif
    }

    static func containerIdentifier(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decode(
        _ results: [(CKRecord.ID, Result<CKRecord, any Error>)]
    ) -> [UserPreset] {
        let decoder = JSONDecoder()
        return results.compactMap { _, result in
            guard case .success(let record) = result,
                let data = record[payloadKey] as? Data
            else { return nil }
            return try? decoder.decode(UserPreset.self, from: data)
        }
    }
}

enum PresetSyncError: Error {
    case iCloudNotConfigured
}
