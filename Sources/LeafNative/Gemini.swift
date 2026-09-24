import Foundation

enum GeminiModelCatalog {
    static let defaultModel = "gemini-3.8-flash"
    static let deepResearch = "deep-research-preview-04-2026"
    static let options: [(id: String, name: String)] = [
        ("gemini-3.8-flash", "Gemini 3.8 Flash"),
        ("gemini-3.1-pro-preview", "Gemini 3.1 Pro (Preview)"),
        ("gemini-2.5-pro", "Gemini 2.5 Pro"),
        (deepResearch, "Gemini Deep Research (API billed)"),
    ]

    static func label(for id: String) -> String {
        options.first(where: { $0.id == id })?.name ?? id
    }
}

struct GeminiClient: AIClient {
    struct Auth: Sendable {
        let apiKey: String

        static func apiKey(_ value: String) -> Self {
            .init(apiKey: value)
        }
    }

    let auth: Auth
    let model: String
    var session: URLSession = .shared

    private static let baseURL = "https://generativelanguage.googleapis.com/v1beta"

    static func validate(auth: Auth, session: URLSession = .shared) async throws {
        var client = GeminiClient(auth: auth, model: GeminiModelCatalog.defaultModel)
        client.session = session
        let (data, response) = try await session.data(for: try await client.request(
            path: "/models?pageSize=1", method: "GET"
        ))
        try check(response: response, data: data)
    }

    func respond(system: String?, prompt: String) async throws -> String {
        var output = ""
        for try await delta in stream(system: system, prompt: prompt) { output += delta }
        return output
    }

    func stream(system: String?, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if model == GeminiModelCatalog.deepResearch {
                        try await streamDeepResearch(system: system, prompt: prompt, continuation: continuation)
                    } else {
                        try await streamModel(system: system, prompt: prompt, continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamModel(
        system: String?, prompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let body = try modelRequestBody(system: system, prompt: prompt)
        let (bytes, response) = try await session.bytes(for: try await request(
            path: "/interactions?alt=sse", method: "POST", body: body
        ))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AIError.requestFailed("Gemini request failed: \(try await errorMessage(from: bytes))")
        }
        var parser = GeminiStreamParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let delta = try parser.consume(line), !delta.isEmpty {
                continuation.yield(delta)
            }
        }
        guard parser.completed, parser.receivedText else { throw AIError.badResponse }
    }

    private func streamDeepResearch(
        system: String?, prompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let input = [system, prompt].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let body = try JSONSerialization.data(withJSONObject: [
            "agent": GeminiModelCatalog.deepResearch,
            "input": input,
            "background": true,
            "store": true,
            "agent_config": ["type": "deep-research"],
        ])
        let (initialData, initialResponse) = try await session.data(for: try await request(
            path: "/interactions", method: "POST", body: body
        ))
        try Self.check(response: initialResponse, data: initialData)
        let initial = try GeminiInteraction.parse(initialData)
        guard let id = initial.id, id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw AIError.badResponse
        }
        var finished = false
        defer {
            let shouldCancel = !finished
            Task.detached {
                if shouldCancel { try? await controlInteraction(id: id, action: "cancel") }
                try? await controlInteraction(id: id, action: "delete")
            }
        }
        var interaction = initial
        for _ in 0..<780 {
            try Task.checkCancellation()
            switch interaction.status {
            case "completed":
                finished = true
                guard let report = interaction.outputText, !report.isEmpty else { throw AIError.badResponse }
                continuation.yield(report)
                return
            case "failed", "cancelled", "incomplete", "requires_action":
                finished = true
                throw AIError.requestFailed(interaction.errorMessage ?? "Gemini Deep Research ended: \(interaction.status)")
            default:
                try await Task.sleep(for: .seconds(5))
                let (data, response) = try await session.data(for: try await request(
                    path: "/interactions/\(id)", method: "GET"
                ))
                try Self.check(response: response, data: data)
                interaction = try GeminiInteraction.parse(data)
            }
        }
        throw AIError.requestFailed("Gemini Deep Research is still running after 65 minutes. Try again later.")
    }

    private func controlInteraction(id: String, action: String) async throws {
        let path = "/interactions/\(id)" + (action == "cancel" ? "/cancel" : "")
        let (data, response) = try await session.data(for: try await request(
            path: path, method: action == "cancel" ? "POST" : "DELETE"
        ))
        try Self.check(response: response, data: data)
    }

    func modelRequestBody(system: String?, prompt: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": prompt,
            "system_instruction": system ?? "",
            "stream": true,
            "store": false,
        ])
    }

    func request(
        path: String, method: String, body: Data? = nil
    ) async throws -> URLRequest {
        guard let url = URL(string: Self.baseURL + path) else { throw AIError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision")
        request.httpBody = body
        request.setValue(auth.apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    static func check(response: URLResponse, data: Data) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw AIError.badResponse }
        guard (200..<300).contains(status) else {
            throw AIError.requestFailed("Gemini request failed (HTTP \(status)): \(errorMessage(from: data))")
        }
    }

    static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = json["error"] as? [String: Any],
           let message = detail["message"] as? String {
            return message
        }
        return String(decoding: data.prefix(500), as: UTF8.self)
    }

    private func errorMessage(from bytes: URLSession.AsyncBytes) async throws -> String {
        var lines = ""
        for try await line in bytes.lines {
            lines += line
            if lines.count > 2_000 { break }
        }
        return Self.errorMessage(from: Data(lines.utf8))
    }
}

struct GeminiStreamParser {
    private var stepTypes: [Int: String] = [:]
    private(set) var completed = false
    private(set) var receivedText = false

    mutating func consume(_ line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]",
              let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        else { return nil }
        let event = json["event_type"] as? String
        switch event {
        case "step.start":
            if let index = json["index"] as? Int,
               let step = json["step"] as? [String: Any] {
                stepTypes[index] = step["type"] as? String
            }
        case "step.delta":
            guard let index = json["index"] as? Int,
                  stepTypes[index] == "model_output",
                  let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text",
                  let text = delta["text"] as? String
            else { return nil }
            receivedText = true
            return text
        case "interaction.completed":
            completed = true
        case "interaction.failed":
            let interaction = json["interaction"] as? [String: Any]
            let error = interaction?["error"] as? [String: Any]
            throw AIError.requestFailed(error?["message"] as? String ?? "Gemini response failed.")
        default:
            break
        }
        return nil
    }
}

struct GeminiInteraction {
    let id: String?
    let status: String
    let outputText: String?
    let errorMessage: String?

    static func parse(_ data: Data) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badResponse
        }
        let value = root["interaction"] as? [String: Any] ?? root
        let output = value["output_text"] as? String
        let steps = value["steps"] as? [[String: Any]] ?? []
        let contents = steps.filter { $0["type"] as? String == "model_output" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let texts = contents.compactMap { $0["text"] as? String }
        let sources = contents.flatMap { $0["annotations"] as? [[String: Any]] ?? [] }
            .compactMap { annotation -> (String, String)? in
                guard annotation["type"] as? String == "url_citation",
                      let address = (annotation["url"] ?? annotation["uri"]) as? String,
                      let url = URL(string: address),
                      ["https", "http"].contains(url.scheme?.lowercased() ?? "")
                else { return nil }
                let title = (annotation["title"] as? String ?? url.host ?? address)
                    .replacingOccurrences(of: "[", with: "")
                    .replacingOccurrences(of: "]", with: "")
                return (title, address)
            }
        var seen = Set<String>()
        let sourceLines = sources.compactMap { title, address -> String? in
            guard seen.insert(address).inserted else { return nil }
            return "- [\(title)](\(address))"
        }
        let report = output ?? (texts.isEmpty ? nil : texts.joined(separator: "\n\n"))
        let citedReport = report.map { value in
            sourceLines.isEmpty ? value : value + "\n\n### Sources\n" + sourceLines.joined(separator: "\n")
        }
        let error = value["error"] as? [String: Any]
        let errors = value["errors"] as? [[String: Any]]
        return .init(
            id: value["id"] as? String,
            status: value["status"] as? String ?? "",
            outputText: citedReport,
            errorMessage: error?["message"] as? String ?? errors?.first?["message"] as? String
        )
    }
}
