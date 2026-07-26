import Foundation

enum Analytics {
    static func record(_ name: String, enabled: Bool) {
        guard enabled else { return }
        Task {
            do {
                let body = Event(deviceId: await FocelleAPI.deviceID(), name: name)
                var request = try await FocelleAPI.request(path: "v1/events", method: "POST")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(body)
                _ = try await URLSession.shared.data(for: request)
            } catch {
                // Analytics never interrupts camera behavior.
            }
        }
    }
}

private struct Event: Encodable {
    let deviceId: String
    let name: String
}
