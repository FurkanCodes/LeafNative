import AppKit
import CryptoKit
import Foundation
import Network
import Security

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Provider

enum AIProvider: String, CaseIterable, Identifiable {
    case appleIntelligence
    case openAI
    case chatGPT
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence (on-device)"
        case .openAI: "OpenAI API"
        case .chatGPT: "ChatGPT account"
        case .gemini: "Gemini"
        }
    }

    var detail: String {
        switch self {
        case .appleIntelligence:
            "Free, private, offline. Requires macOS 26 and Apple Intelligence."
        case .openAI:
            "Connect with an OpenAI Platform API key. API usage is billed separately from ChatGPT."
        case .chatGPT:
            "Use your ChatGPT subscription through the Codex sign-in flow. This integration depends on Codex's private backend."
        case .gemini:
            "Connect with a Gemini API key. Usage belongs to the key's Google Cloud project and is separate from Gemini app subscriptions."
        }
    }
}

enum AIError: LocalizedError {
    case appleIntelligenceUnavailable
    case requestFailed(String)
    case badResponse
    case authCancelled
    case authFailed(String)

    var errorDescription: String? {
        switch self {
        case .appleIntelligenceUnavailable:
            "Apple Intelligence is not available on this Mac."
        case .requestFailed(let detail):
            detail
        case .badResponse:
            "The AI service returned an unexpected response."
        case .authCancelled:
            "Sign-in was cancelled or timed out."
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

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            ) == errSecSuccess
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
    }

    @discardableResult
    static func remove(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - Conversation

enum AIStatus: Equatable {
    case idle
    case working
    case failed(String)
}

// MARK: - Clients

protocol AIClient: Sendable {
    func respond(system: String?, prompt: String) async throws -> String
    func stream(system: String?, prompt: String) -> AsyncThrowingStream<String, Error>
}

extension AIClient {
    func stream(system: String?, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await respond(system: system, prompt: prompt))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct OpenAIClient: AIClient {
    var apiKey: String
    var model: String = AIModelCatalog.defaultModel
    var session: URLSession = .shared

    struct Request: Encodable {
        let model: String
        let instructions: String?
        let input: String
        let store = false
    }

    private struct StreamRequest: Encodable {
        let model: String
        let instructions: String?
        let input: String
        let store = false
        let stream = true
    }

    struct Response: Decodable {
        struct Item: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
            }
            let type: String
            let content: [Content]?
        }
        let output: [Item]

        var text: String? {
            let parts = output
                .filter { $0.type == "message" }
                .flatMap { $0.content ?? [] }
                .compactMap { $0.type == "output_text" ? $0.text : nil }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
    }

    private struct APIError: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    func validateKey() async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
    }

    func respond(system: String?, prompt: String) async throws -> String {
        var request = URLRequest(
            url: URL(string: "https://api.openai.com/v1/responses")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(apiKey)", forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(
            Request(model: model, instructions: system, input: prompt)
        )

        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, data: data)
        guard let text = try JSONDecoder().decode(Response.self, from: data).text
        else { throw AIError.badResponse }
        return text
    }

    func stream(system: String?, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.httpBody = try JSONEncoder().encode(
                        StreamRequest(model: model, instructions: system, input: prompt)
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw AIError.requestFailed("OpenAI request failed.")
                    }
                    var parser = AIStreamParser()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let delta = try parser.consume(line), !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func check(response: URLResponse, data: Data) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw AIError.badResponse
        }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(APIError.self, from: data))?
                .error.message ?? "HTTP \(status)"
            throw AIError.requestFailed("OpenAI: \(message)")
        }
    }
}

enum AIModelCatalog {
    static let defaultModel = "gpt-5.6-luna"
    static let options: [(id: String, name: String)] = [
        ("gpt-5.6-luna", "GPT-5.6 Luna"),
        ("gpt-5.6-terra", "GPT-5.6 Terra"),
        ("gpt-5.6-sol", "GPT-5.6 Sol"),
        ("gpt-6-astra", "GPT-6 Astra"),
    ]
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

    func stream(system: String?, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let session: LanguageModelSession
                if let system, !system.isEmpty {
                    session = LanguageModelSession(instructions: system)
                } else {
                    session = LanguageModelSession()
                }
                var previous = ""
                do {
                    for try await snapshot in session.streamResponse(to: prompt) {
                        try Task.checkCancellation()
                        let content = snapshot.content
                        let delta = content.hasPrefix(previous)
                            ? String(content.dropFirst(previous.count))
                            : content
                        if !delta.isEmpty { continuation.yield(delta) }
                        previous = content
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif

// MARK: - ChatGPT OAuth (Codex client flow)

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
        KeychainStore.get(account: keychainAccount)
            .flatMap { Data($0.utf8) }
            .flatMap { try? JSONDecoder().decode(ChatGPTCredentials.self, from: $0) }
    }

    static func signOut() {
        KeychainStore.remove(account: keychainAccount)
    }

    private static func save(_ value: ChatGPTCredentials) throws {
        let data = try JSONEncoder().encode(value)
        guard KeychainStore.set(
            String(decoding: data, as: UTF8.self),
            account: keychainAccount
        ) else {
            throw AIError.authFailed("Could not save ChatGPT sign-in in Keychain.")
        }
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
                value: "openid profile email offline_access api.connectors.read api.connectors.invoke"
            ),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "originator", value: "leaf_native"),
        ]
        guard let authURL = components.url else { throw AIError.badResponse }
        let callback = try await server.waitForCallback(
            expectedState: state,
            authorizationURL: authURL
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
        try save(credentials)
        return credentials
    }

    static func refreshIfNeeded(
        _ credentials: ChatGPTCredentials,
        force: Bool = false
    ) async throws -> ChatGPTCredentials {
        let expiry = expiration(from: credentials.accessToken)
        let needsRefresh = force || (expiry.map { $0 < Date().addingTimeInterval(300) }
            ?? (Date().timeIntervalSince(credentials.obtainedAt) > 3600))
        guard needsRefresh else { return credentials }
        guard let refreshToken = credentials.refreshToken else {
            throw AIError.authFailed("ChatGPT session expired. Sign in again in Settings.")
        }
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
            if let accountID = accountID(from: idToken) {
                refreshed.accountID = accountID
            }
        }
        refreshed.obtainedAt = Date()
        try save(refreshed)
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
        var form = URLComponents()
        form.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

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

    private static func expiration(from token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let seconds = json["exp"] as? TimeInterval
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
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
private final class LoopbackServer: @unchecked Sendable {
    private final class Once: @unchecked Sendable {
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

    func waitForCallback(
        expectedState: String,
        authorizationURL: URL
    ) async throws -> URL {
        let listener = try NWListener(using: .tcp, on: 1455)
        defer { listener.cancel() }
        let completed = Once()
        let opened = Once()
        return try await withCheckedThrowingContinuation { continuation in
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                    data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let target = request.components(separatedBy: "\r\n")
                        .first.flatMap { $0.split(separator: " ").dropFirst().first }
                        .map(String.init)
                    let url = target.flatMap { URL(string: "http://localhost\($0)") }
                    let components = url.flatMap {
                        URLComponents(url: $0, resolvingAgainstBaseURL: false)
                    }
                    let validPath = components?.path == "/auth/callback"
                    let validState = components?.queryItems?
                        .first(where: { $0.name == "state" })?.value == expectedState
                    let accepted = validPath && validState && completed.claim()
                    let hasCode = components?.queryItems?.contains(where: { $0.name == "code" })
                        == true
                    let body = accepted
                        ? (hasCode
                            ? "<h2>Signed in to Leaf Native</h2><p>You can close this tab.</p>"
                            : "<h2>Sign-in was not completed</h2><p>Return to Leaf Native.</p>")
                        : "<h2>Invalid sign-in callback</h2>"
                    let status = accepted ? "200 OK" : "400 Bad Request"
                    let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(
                        content: Data(response.utf8),
                        completion: .contentProcessed { _ in connection.cancel() }
                    )
                    if accepted, let url {
                        continuation.resume(returning: url)
                    }
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready where opened.claim():
                    Task { @MainActor in
                        if !NSWorkspace.shared.open(authorizationURL), completed.claim() {
                            continuation.resume(throwing: AIError.authFailed(
                                "Could not open the ChatGPT sign-in page."
                            ))
                        }
                    }
                case .failed(let error) where completed.claim():
                    continuation.resume(throwing: AIError.authFailed(
                        "Local sign-in server failed: \(error.localizedDescription)"
                    ))
                default:
                    break
                }
            }
            listener.start(queue: .global())
            Task {
                try? await Task.sleep(for: .seconds(300))
                if completed.claim() {
                    continuation.resume(throwing: AIError.authCancelled)
                }
            }
        }
    }
}

// MARK: - ChatGPT client (Codex streaming backend)

struct AIStreamParser {
    private(set) var receivedDelta = false

    mutating func consume(_ line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard let json = try? JSONSerialization.jsonObject(
            with: Data(payload.utf8)
        ) as? [String: Any] else { return nil }
        switch json["type"] as? String {
        case "response.output_text.delta":
            receivedDelta = true
            return json["delta"] as? String
        case "response.completed":
            if !receivedDelta,
               let response = json["response"] as? [String: Any] {
                return ChatGPTClient.outputText(from: response)
            }
        case "response.failed":
            let response = json["response"] as? [String: Any]
            let detail = response?["error"] as? [String: Any]
            throw AIError.requestFailed(
                detail?["message"] as? String ?? "The AI response failed."
            )
        default:
            break
        }
        return nil
    }
}

struct ChatGPTClient: AIClient {
    var credentials: ChatGPTCredentials
    var model: String = AIModelCatalog.defaultModel
    var session: URLSession = .shared

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
        let instructions: String
        let input: [Input]
        let stream = true
        let store = false
    }

    func respond(system: String?, prompt: String) async throws -> String {
        var fresh = try await ChatGPTAuth.refreshIfNeeded(credentials)
        let instructions = (system?.isEmpty == false ? system : nil)
            ?? "You are a helpful reading assistant."
        let body = try JSONEncoder().encode(
            RequestBody(
                model: model,
                instructions: instructions,
                input: [.init(role: "user", content: [.init(text: prompt)])]
            )
        )
        var (data, response) = try await session.data(
            for: makeRequest(credentials: fresh, body: body)
        )
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            fresh = try await ChatGPTAuth.refreshIfNeeded(fresh, force: true)
            (data, response) = try await session.data(
                for: makeRequest(credentials: fresh, body: body)
            )
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw AIError.badResponse
        }
        guard status == 200 else {
            let detail = String(data: data, encoding: .utf8)?.prefix(250)
            throw AIError.requestFailed(
                "ChatGPT request failed (HTTP \(status)): \(detail ?? "No details")"
            )
        }
        return try Self.extractText(from: data)
    }

    func stream(system: String?, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var fresh = try await ChatGPTAuth.refreshIfNeeded(credentials)
                    let instructions = (system?.isEmpty == false ? system : nil)
                        ?? "You are a helpful reading assistant."
                    let body = try JSONEncoder().encode(
                        RequestBody(
                            model: model,
                            instructions: instructions,
                            input: [.init(role: "user", content: [.init(text: prompt)])]
                        )
                    )
                    var (bytes, response) = try await session.bytes(
                        for: makeRequest(credentials: fresh, body: body)
                    )
                    if (response as? HTTPURLResponse)?.statusCode == 401 {
                        fresh = try await ChatGPTAuth.refreshIfNeeded(fresh, force: true)
                        (bytes, response) = try await session.bytes(
                            for: makeRequest(credentials: fresh, body: body)
                        )
                    }
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw AIError.requestFailed("ChatGPT request failed.")
                    }
                    var parser = AIStreamParser()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let delta = try parser.consume(line), !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(
        credentials: ChatGPTCredentials,
        body: Data
    ) -> URLRequest {
        var request = URLRequest(
            url: URL(
                string: "https://chatgpt.com/backend-api/codex/responses"
            )!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(credentials.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-ID"
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("responses=v1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("leaf_native", forHTTPHeaderField: "originator")
        request.setValue(
            UUID().uuidString, forHTTPHeaderField: "session_id"
        )
        request.httpBody = body
        return request
    }

    static func extractText(from data: Data) throws -> String {
        guard let stream = String(data: data, encoding: .utf8) else {
            throw AIError.badResponse
        }
        var deltas = ""
        var completedText: String?
        for line in stream.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n") where line.hasPrefix("data:") {
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let json = try? JSONSerialization.jsonObject(
                with: Data(payload.utf8)
            ) as? [String: Any] else { continue }
            switch json["type"] as? String {
            case "response.output_text.delta":
                deltas += json["delta"] as? String ?? ""
            case "response.completed":
                if let response = json["response"] as? [String: Any] {
                    completedText = outputText(from: response)
                }
            case "response.failed":
                let response = json["response"] as? [String: Any]
                let error = response?["error"] as? [String: Any]
                throw AIError.requestFailed(
                    error?["message"] as? String ?? "ChatGPT response failed."
                )
            default:
                break
            }
        }
        if let completedText, !completedText.isEmpty { return completedText }
        guard !deltas.isEmpty else { throw AIError.badResponse }
        return deltas
    }

    static func outputText(from response: [String: Any]) -> String? {
        guard let output = response["output"] as? [[String: Any]] else { return nil }
        let parts = output.compactMap { item -> [String]? in
            guard item["type"] as? String == "message",
                  let content = item["content"] as? [[String: Any]]
            else { return nil }
            return content.compactMap {
                $0["type"] as? String == "output_text" ? $0["text"] as? String : nil
            }
        }.flatMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
