import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security

@MainActor
final class Account: ObservableObject {
    @Published private(set) var credits = 0
    @Published private(set) var isLoading = false
    @Published var messageKey: String?
    private var nonce: String?

    var isSignedIn: Bool { AccountSession.load() != nil }

    func configure(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        self.nonce = nonce
        request.requestedScopes = []
        request.nonce = Self.sha256(nonce)
    }

    func complete(_ result: Result<ASAuthorization, Error>) {
        guard case let .success(authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8),
              let nonce
        else {
            messageKey = "account.error.signIn"
            return
        }
        self.nonce = nil
        Task { await signIn(identityToken: identityToken, nonce: nonce) }
    }

    func refresh() async {
        guard let session = AccountSession.load() else {
            credits = 0
            objectWillChange.send()
            return
        }
        do {
            var request = try await FocelleAPI.request(path: "v1/account")
            request.setValue(session, forHTTPHeaderField: "X-Focelle-Session")
            let response = try await send(request)
            credits = response.credits
        } catch AccountError.unauthorized {
            signOut()
        } catch {
            messageKey = "account.error.sync"
        }
    }

    func delete() async {
        guard let session = AccountSession.load() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var request = try await FocelleAPI.request(path: "v1/account", method: "DELETE")
            request.setValue(session, forHTTPHeaderField: "X-Focelle-Session")
            _ = try await send(request)
            signOut()
            messageKey = "account.deleted"
        } catch {
            messageKey = "account.error.delete"
        }
    }

    func signOut() {
        AccountSession.clear()
        credits = 0
        objectWillChange.send()
    }

    private func signIn(identityToken: String, nonce: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var request = try await FocelleAPI.request(path: "v1/account/apple", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                AppleLoginRequest(
                    deviceId: await FocelleAPI.deviceID(),
                    identityToken: identityToken,
                    nonce: nonce
                )
            )
            let response = try await send(request)
            guard let token = response.sessionToken else { throw AccountError.server }
            AccountSession.save(token)
            credits = response.credits
            messageKey = nil
            objectWillChange.send()
        } catch {
            messageKey = "account.error.signIn"
        }
    }

    private func send(_ request: URLRequest) async throws -> AccountResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountError.server }
        if http.statusCode == 401 { throw AccountError.unauthorized }
        guard (200...299).contains(http.statusCode),
              let value = try? JSONDecoder().decode(AccountResponse.self, from: data),
              value.ok
        else { throw AccountError.server }
        return value
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let count = bytes.count
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private enum AccountError: Error {
        case unauthorized
        case server
    }
}

enum AccountSession {
    private static let service = "com.pnhd.focelle.account"
    private static let account = "session"

    static func save(_ token: String) {
        clear()
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(token.utf8),
        ] as CFDictionary, nil)
    }

    static func load() -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
    }
}

private struct AppleLoginRequest: Encodable {
    let deviceId: String
    let identityToken: String
    let nonce: String
}

private struct AccountResponse: Decodable {
    let ok: Bool
    let sessionToken: String?
    let credits: Int
}
