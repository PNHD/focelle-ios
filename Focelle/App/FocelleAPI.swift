import Foundation
import UIKit

enum FocelleAPI {
    static func request(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = []
    ) async throws -> URLRequest {
        guard
            let endpointText = Bundle.main.object(
                forInfoDictionaryKey: "FocelleAIEndpoint"
            ) as? String,
            let endpoint = URL(string: endpointText),
            endpoint.scheme == "https",
            let token = Bundle.main.object(
                forInfoDictionaryKey: "FocelleAISharedToken"
            ) as? String,
            !token.isEmpty
        else {
            throw AIClientError.unavailable
        }
        var url = endpoint.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func deviceID() async -> String {
        await MainActor.run {
            UIDevice.current.identifierForVendor?
                .uuidString.replacingOccurrences(of: "-", with: "")
                ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
    }
}
