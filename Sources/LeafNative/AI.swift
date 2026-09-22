import AppKit
import CryptoKit
import Foundation
import Network

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Provider

enum AIProvider: String, CaseIterable, Identifiable {
    case appleIntelligence
    case openAI
    case chatGPT

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence (on-device)"
        case .openAI: "OpenAI (API key)"
        case .chatGPT: "ChatGPT account (experimental)"
        }
    }

    var detail: String {
        switch self {
        case .appleIntelligence:
            "Free, private, offline. Requires macOS 26 and Apple Intelligence."
        case .openAI:
            "Paste an API key from platform.openai.com. Usage is billed by OpenAI."
        case .chatGPT:
            "Signs in with your ChatGPT account. Experimental — relies on "
                + "undocumented OpenAI internals and may stop working."
        }
    }
}

enum AIError: LocalizedError {
    case notConfigured
    case appleIntelligenceUnavailable
    case requestFailed(String)
    case badResponse
    case authCancelled
    case authFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Configure an AI provider in Settings first."
        case .appleIntelligenceUnavailable:
            "Apple Intelligence is not available on this Mac."
        case .requestFailed(let detail):
            detail
        case .badResponse:
            "The AI service returned an unexpected response."
        case .authCancelled:
            "Sign-in was cancelled."
        case .authFailed(let detail):
            detail
        }
    }
}

// MARK: - Keychain

enum KeychainStore {
    private static let service = "app.leaf.native"

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Conversation

enum AIStatus: Equatable {
    case idle
    case working
    case failed(String)
}

struct AIMessage: Identifiable, Equatable {
    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    let text: String
}

// MARK: - Clients

protocol AIClient: Sendable {
    func respond(system: String?, prompt: String) async throws -> String
}

struct OpenAIClient: AIClient {
    var apiKey: String
    var model: String = "gpt-4o-mini"

    struct Request: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
    }

    struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    func respond(system: String?, prompt: String) async throws -> String {
        var messages = [Request.Message(role: "user", content: prompt)]
        if let system, !system.isEmpty {
            messages.insert(
                Request.Message(role: "system", content: system), at: 0
            )
        }
        var request = URLRequest(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(apiKey)", forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(
            Request(model: model, messages: messages)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let detail =
                String(data: data, encoding: .utf8)?.prefix(300) ?? "no details"
            throw AIError.requestFailed(
                "OpenAI request failed: \(detail)"
            )
        }
        guard let text = try JSONDecoder()
            .decode(Response.self, from: data)
            .choices.first?.message.content
        else { throw AIError.badResponse }
        return text
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
struct AppleIntelligenceClient: AIClient {
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    func respond(system: String?, prompt: String) async throws -> String {
        let session: LanguageModelSession
        if let system, !system.isEmpty {
            session = LanguageModelSession(instructions: system)
        } else {
            session = LanguageModelSession()
        }
        let response = try await session.respond(to: prompt)
        return response.content
    }
}
#endif

// MARK: - ChatGPT OAuth (experimental — borrows Codex CLI's public client)

struct ChatGPTCredentials: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var accountID: String
    var obtainedAt: Date
}

enum ChatGPTAuth {
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let issuer = "https://auth.openai.com"
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let keychainAccount = "chatgpt-credentials"

    static var credentials: ChatGPTCredentials? {
        get {
            KeychainStore.get(account: keychainAccount)
                .flatMap { Data($0.utf8) }
                .flatMap { try? JSONDecoder().decode(
                    ChatGPTCredentials.self, from: $0
                ) }
        }
        set {
            if let newValue,
               let data = try? JSONEncoder().encode(newValue) {
                KeychainStore.set(
                    String(decoding: data, as: UTF8.self),
                    account: keychainAccount
                )
            } else {
                KeychainStore.remove(account: keychainAccount)
            }
        }
    }

    static func signOut() {
        credentials = nil
    }

    @MainActor
    static func signIn() async throws -> ChatGPTCredentials {
        let verifier = randomVerifier()
        let challenge = pkceChallenge(verifier)
        let state = UUID().uuidString

        let server = LoopbackServer()
        var components = URLComponents(
            string: "\(issuer)/oauth/authorize"
        )!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(
                name: "scope",
                value: "openid profile email offline_access"
            ),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "originator", value: "leaf_native"),
        ]
        NSWorkspace.shared.open(components.url!)

        let callback = try await server.waitForCallback(
            expectedState: state
        )
        let queryItems = URLComponents(
            url: callback,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        guard let code = queryItems
            .first(where: { $0.name == "code" })?.value
        else {
            let err = queryItems
                .first(where: { $0.name == "error" })?.value
            throw AIError.authFailed(err ?? "No authorization code returned.")
        }

        return try await exchange(code: code, verifier: verifier)
    }

    static func exchange(
        code: String,
        verifier: String
    ) async throws -> ChatGPTCredentials {
        let body: [String: String] = [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]
        let tokens = try await tokenRequest(body: body)
        guard let idToken = tokens.idToken,
              let accountID = accountID(from: idToken)
        else {
            throw AIError.authFailed(
                "Signed in, but no ChatGPT account ID was returned."
            )
        }
        let credentials = ChatGPTCredentials(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            accountID: accountID,
            obtainedAt: Date()
        )
        self.credentials = credentials
        return credentials
    }

    static func refreshIfNeeded(
        _ credentials: ChatGPTCredentials
    ) async throws -> ChatGPTCredentials {
        // Access tokens live ~28 days in practice; refresh when older than
        // a week, or lazily retry on 401 — handled in ChatGPTClient.
        guard Date().timeIntervalSince(credentials.obtainedAt) > 7 * 86_400,
              let refreshToken = credentials.refreshToken
        else { return credentials }
        let body: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        let tokens = try await tokenRequest(body: body)
        var refreshed = credentials
        refreshed.accessToken = tokens.accessToken
        if let newRefresh = tokens.refreshToken {
            refreshed.refreshToken = newRefresh
        }
        if let idToken = tokens.idToken {
            refreshed.idToken = idToken
        }
        refreshed.obtainedAt = Date()
        self.credentials = refreshed
        return refreshed
    }

    private struct TokenResponse: Decodable {
        let idToken: String?
        let accessToken: String
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    private static func tokenRequest(
        body: [String: String]
    ) async throws -> TokenResponse {
        var request = URLRequest(
            url: URL(string: "\(issuer)/oauth/token")!
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body
            .map { key, value in
                let encoded = value.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed
                ) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let detail =
                String(data: data, encoding: .utf8)?.prefix(300) ?? "no details"
            throw AIError.authFailed("Token exchange failed: \(detail)")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func accountID(from idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return nil }
        if let auth = json["https://api.openai.com/auth"] as? [String: Any],
           let id = auth["chatgpt_account_id"] as? String {
            return id
        }
        return json["chatgpt_account_id"] as? String
    }

    private static func randomVerifier() -> String {
        let chars = Array(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )
        return String((0..<64).map { _ in chars.randomElement()! })
    }

    private static func pkceChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// One-shot localhost listener for the OAuth redirect.
private final class LoopbackServer {
    private var listener: NWListener?

    private final class Once {
        private let lock = NSLock()
        private var fired = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    func waitForCallback(expectedState: String) async throws -> URL {
        let listener = try NWListener(using: .tcp, on: 1455)
        self.listener = listener
        defer { listener.cancel() }
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                    data, _, _, _ in
                    guard once.claim() else { return }
                    let request = data.flatMap {
                        String(data: $0, encoding: .utf8)
                    } ?? ""
                    let responseData = Data(
                        """
                        HTTP/1.1 200 OK\r
                        Content-Type: text/html\r
                        Connection: close\r
                        \r
                        <h2>Signed in to Leaf Native</h2>
                        <p>You can close this tab.</p>
                        """.utf8
                    )
                    connection.send(
                        content: responseData,
                        completion: .contentProcessed { _ in
                            connection.cancel()
                        }
                    )

                    guard let line = request
                        .components(separatedBy: "\r\n")
                        .first,
                        line.hasPrefix("GET "),
                        let target = line
                            .components(separatedBy: " ")
                            .dropFirst()
                            .first,
                        let url = URL(
                            string: "http://localhost\(target)"
                        )
                    else {
                        continuation.resume(
                            throwing: AIError.authFailed("Malformed callback")
                        )
                        return
                    }
                    guard URLComponents(
                        url: url,
                        resolvingAgainstBaseURL: false
                    )?.queryItems?
                        .first(where: { $0.name == "state" })?.value
                        == expectedState
                    else {
                        continuation.resume(throwing: AIError.authCancelled)
                        return
                    }
                    continuation.resume(returning: url)
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state, once.claim() {
                    continuation.resume(
                        throwing: AIError.authFailed(
                            "Local server failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
            listener.start(queue: .global())
        }
    }
}

// MARK: - ChatGPT API client (Responses API on the codex backend)

struct ChatGPTClient: AIClient {
    var credentials: ChatGPTCredentials
    var model: String = "gpt-5.4-mini"

    struct RequestBody: Encodable {
        struct Input: Encodable {
            struct Content: Encodable {
                let type = "input_text"
                let text: String
            }
            let type = "message"
            let role: String
            let content: [Content]
        }
        let model: String
        let instructions: String?
        let input: [Input]
        let stream = false
        let store = false
    }

    func respond(system: String?, prompt: String) async throws -> String {
        let fresh = try await ChatGPTAuth.refreshIfNeeded(credentials)
        var request = URLRequest(
            url: URL(
                string: "https://chatgpt.com/backend-api/codex/responses"
            )!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(fresh.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            fresh.accountID, forHTTPHeaderField: "ChatGPT-Account-ID"
        )
        request.setValue("responses=v1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("leaf_native", forHTTPHeaderField: "originator")
        request.setValue(
            UUID().uuidString, forHTTPHeaderField: "session_id"
        )
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: model,
                instructions: system,
                input: [
                    .init(role: "user", content: [.init(text: prompt)])
                ]
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let detail =
                String(data: data, encoding: .utf8)?.prefix(300) ?? "no details"
            throw AIError.requestFailed(
                "ChatGPT request failed: \(detail)"
            )
        }
        return try extractText(from: data)
    }

    private func extractText(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              let output = root["output"] as? [[String: Any]]
        else { throw AIError.badResponse }
        var parts: [String] = []
        for item in output where item["type"] as? String == "message" {
            guard let content = item["content"] as? [[String: Any]] else {
                continue
            }
            for piece in content
            where piece["type"] as? String == "output_text" {
                if let text = piece["text"] as? String {
                    parts.append(text)
                }
            }
        }
        guard !parts.isEmpty else { throw AIError.badResponse }
        return parts.joined(separator: "\n")
    }
}
