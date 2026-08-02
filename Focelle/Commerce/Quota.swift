import Combine
import Foundation

@MainActor
final class Quota: ObservableObject {
    struct Snapshot: Codable, Equatable {
        var unlimited: Bool
        var aiRemaining: Int
        var filterRemaining: Int
        var adsRemaining: Int
        var localDay: String
    }

    enum QuotaError: Error {
        case exhausted
        case featureDisabled
        case server
    }

    @Published private(set) var snapshot: Snapshot
    private let defaults: UserDefaults
    private static let cacheKey = "quota"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snapshot =
            defaults.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
            ?? Snapshot(
                unlimited: true,
                aiRemaining: 5,
                filterRemaining: 5,
                adsRemaining: 5,
                localDay: ""
            )
    }

    func refresh() async {
        do {
            let deviceId = await FocelleAPI.deviceID()
            let request = try await FocelleAPI.request(
                path: "v1/quota",
                query: [
                    URLQueryItem(name: "deviceId", value: deviceId),
                    URLQueryItem(
                        name: "timezoneOffsetMinutes",
                        value: String(TimeZone.current.secondsFromGMT() / 60)
                    ),
                ]
            )
            try await update(from: request)
        } catch {
            // Cached quota keeps the camera usable offline.
        }
    }

    func consumeFilter() async throws {
        try await post(
            path: "v1/quota",
            body: QuotaRequest(
                deviceId: await FocelleAPI.deviceID(),
                timezoneOffsetMinutes: TimeZone.current.secondsFromGMT() / 60,
                kind: "filter",
                requestId: UUID().uuidString.replacingOccurrences(of: "-", with: "")
            )
        )
    }

    func grantTestReward(_ rewardId: String) async throws {
        try await post(
            path: "v1/rewards/test",
            body: RewardRequest(
                deviceId: await FocelleAPI.deviceID(),
                timezoneOffsetMinutes: TimeZone.current.secondsFromGMT() / 60,
                rewardId: rewardId
            )
        )
    }

    private func post<T: Encodable>(path: String, body: T) async throws {
        var request = try await FocelleAPI.request(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        try await update(from: request)
    }

    private func update(from request: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QuotaError.server }
        if http.statusCode == 402 { throw QuotaError.exhausted }
        if http.statusCode == 403 { throw QuotaError.featureDisabled }
        guard http.statusCode == 200,
            let envelope = try? JSONDecoder().decode(QuotaResponse.self, from: data),
            envelope.ok
        else { throw QuotaError.server }
        snapshot = envelope.quota
        if let cache = try? JSONEncoder().encode(snapshot) {
            defaults.set(cache, forKey: Self.cacheKey)
        }
    }
}

private struct QuotaResponse: Decodable {
    let ok: Bool
    let quota: Quota.Snapshot
}

private struct QuotaRequest: Encodable {
    let deviceId: String
    let timezoneOffsetMinutes: Int
    let kind: String
    let requestId: String
}

private struct RewardRequest: Encodable {
    let deviceId: String
    let timezoneOffsetMinutes: Int
    let rewardId: String
}
