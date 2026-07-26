import Combine
import Foundation

@MainActor
final class Referral: ObservableObject {
    struct Snapshot: Decodable, Equatable {
        let code: String
        let claimed: Bool
        let qualified: Bool
        let benefitEndsAt: Date?

        private enum CodingKeys: String, CodingKey {
            case code
            case claimed
            case qualified
            case benefitEndsAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            code = try values.decode(String.self, forKey: .code)
            claimed = try values.decode(Bool.self, forKey: .claimed)
            qualified = try values.decode(Bool.self, forKey: .qualified)
            benefitEndsAt = try values.decodeIfPresent(Int64.self, forKey: .benefitEndsAt)
                .map { Date(timeIntervalSince1970: Double($0) / 1_000) }
        }
    }

    @Published private(set) var enabled = false
    @Published private(set) var snapshot: Snapshot?
    @Published var messageKey: String?

    func refresh() async {
        guard let session = AccountSession.load() else {
            enabled = false
            snapshot = nil
            return
        }
        do {
            var request = try await FocelleAPI.request(path: "v1/referral")
            request.setValue(session, forHTTPHeaderField: "X-Focelle-Session")
            snapshot = try await send(request)
            enabled = true
        } catch ReferralError.disabled {
            enabled = false
            snapshot = nil
        } catch {
            messageKey = "referral.error.load"
        }
    }

    func redeem(_ code: String) async {
        guard let session = AccountSession.load() else { return }
        do {
            var request = try await FocelleAPI.request(path: "v1/referral", method: "POST")
            request.setValue(session, forHTTPHeaderField: "X-Focelle-Session")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                ReferralRequest(code: code.uppercased())
            )
            snapshot = try await send(request)
            messageKey = "referral.claimed"
        } catch ReferralError.conflict {
            messageKey = "referral.error.used"
        } catch {
            messageKey = "referral.error.invalid"
        }
    }

    private func send(_ request: URLRequest) async throws -> Snapshot {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReferralError.server }
        if http.statusCode == 403 { throw ReferralError.disabled }
        if http.statusCode == 409 { throw ReferralError.conflict }
        guard http.statusCode == 200,
              let envelope = try? JSONDecoder().decode(ReferralResponse.self, from: data),
              envelope.ok
        else { throw ReferralError.server }
        return envelope.referral
    }

    private enum ReferralError: Error {
        case disabled
        case conflict
        case server
    }
}

private struct ReferralResponse: Decodable {
    let ok: Bool
    let referral: Referral.Snapshot
}

private struct ReferralRequest: Encodable {
    let code: String
}
