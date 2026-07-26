@preconcurrency import CloudKit
import Foundation
import Security

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
        guard let task = SecTaskCreateFromSelf(nil),
              supportsCloudKit(
                  SecTaskCopyValueForEntitlement(
                      task,
                      "com.apple.developer.icloud-services" as CFString,
                      nil
                  )
              ),
              let identifier = Bundle.main.object(
                  forInfoDictionaryKey: containerInfoKey
              ) as? String, !identifier.isEmpty else {
            throw PresetSyncError.iCloudNotConfigured
        }
        return CKContainer(identifier: identifier).privateCloudDatabase
    }

    static func supportsCloudKit(_ services: Any?) -> Bool {
        (services as? [String])?.contains("CloudKit") == true
    }

    private static func decode(
        _ results: [(CKRecord.ID, Result<CKRecord, any Error>)]
    ) -> [UserPreset] {
        let decoder = JSONDecoder()
        return results.compactMap { _, result in
            guard case let .success(record) = result,
                  let data = record[payloadKey] as? Data
            else { return nil }
            return try? decoder.decode(UserPreset.self, from: data)
        }
    }
}

private enum PresetSyncError: Error {
    case iCloudNotConfigured
}
