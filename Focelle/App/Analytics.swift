import Foundation

enum Analytics {
    static func record(
        _ name: String,
        enabled: Bool,
        category: String? = nil,
        latencyBucket: String? = nil,
        schemaVersion: Int? = nil
    ) {
        guard enabled else { return }
        Task {
            do {
                let body = Event(
                    deviceId: await FocelleAPI.deviceID(),
                    name: name,
                    category: category,
                    latencyBucket: latencyBucket,
                    schemaVersion: schemaVersion
                )
                var request = try await FocelleAPI.request(path: "v1/events", method: "POST")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(body)
                _ = try await URLSession.shared.data(for: request)
            } catch {
                // Analytics never interrupts camera behavior.
            }
        }
    }

    static func recordReturnMilestones(
        enabled: Bool,
        now: Date = .now,
        defaults: UserDefaults = .standard
    ) {
        guard enabled else { return }
        let key = "analyticsFirstLaunch"
        guard let firstLaunch = defaults.object(forKey: key) as? Date else {
            defaults.set(now, forKey: key)
            return
        }
        let days = now.timeIntervalSince(firstLaunch) / 86_400
        if days >= 1 { record("day_1_return", enabled: true) }
        if days >= 7 { record("day_7_return", enabled: true) }
    }

    static func latencyBucket(_ seconds: TimeInterval) -> String {
        if seconds < 3 { return "under_3s" }
        if seconds < 8 { return "3_to_8s" }
        return "over_8s"
    }
}

private struct Event: Encodable {
    let deviceId: String
    let name: String
    let category: String?
    let latencyBucket: String?
    let schemaVersion: Int?
}
