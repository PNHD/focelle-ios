import Combine
import Foundation

@MainActor
final class BetaAccess: ObservableObject {
    struct Snapshot: Codable, Equatable {
        var enabled: Bool
        var activated: Bool
        var successfulAnalyses: Int
        var endsAt: Date?
        var activatedUsers: Int
    }

    @Published private(set) var snapshot: Snapshot
    private let defaults: UserDefaults
    private static let cacheKey = "betaAccess"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snapshot =
            defaults.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
            ?? Snapshot(
                enabled: true,
                activated: false,
                successfulAnalyses: 0,
                endsAt: nil,
                activatedUsers: 0
            )
    }

    func refresh() async {
        do {
            let deviceId = await FocelleAPI.deviceID()
            let request = try await FocelleAPI.request(
                path: "v1/config",
                query: [URLQueryItem(name: "deviceId", value: deviceId)]
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                let envelope = try? decoder.decode(ConfigResponse.self, from: data),
                envelope.ok
            else { return }
            snapshot = envelope.beta.snapshot
            if let data = try? JSONEncoder().encode(snapshot) {
                defaults.set(data, forKey: Self.cacheKey)
            }
        } catch {
            // Cached Beta Pro remains usable offline.
        }
    }
}

private struct ConfigResponse: Decodable {
    struct Beta: Decodable {
        let enabled: Bool
        let activated: Bool
        let successfulAnalyses: Int
        let endsAt: Date
        let activatedUsers: Int

        var snapshot: BetaAccess.Snapshot {
            .init(
                enabled: enabled,
                activated: activated,
                successfulAnalyses: successfulAnalyses,
                endsAt: endsAt,
                activatedUsers: activatedUsers
            )
        }
    }

    let ok: Bool
    let beta: Beta
}
