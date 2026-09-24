import Foundation

enum ResearchIntent {
    static func wantsPapers(_ question: String) -> Bool {
        let text = question.lowercased()
        let phrases = [
            "find papers", "find studies", "find research", "related papers",
            "related studies", "research on", "studies on", "papers on",
            "scientific sources", "journal articles", "literature on",
            "doi", "cite research", "researches", "references about",
        ]
        if phrases.contains(where: text.contains) { return true }
        let requestWords = ["find", "link", "recommend", "suggest", "locate", "search"]
        let sourceWords = ["paper", "study", "research", "article", "literature", "source", "citation", "reference"]
        return requestWords.contains(where: text.contains)
            && sourceWords.contains(where: text.contains)
    }

    static func query(question: String, selectedQuote: String) -> String {
        let source = question.lowercased().contains("this excerpt")
            || question.lowercased().contains("this passage")
            ? selectedQuote : question
        let stop: Set<String> = [
            "about", "find", "paper", "papers", "study", "studies", "research",
            "researches", "related", "regarding", "this", "that", "these", "those",
            "excerpt", "passage", "please", "could", "would", "with", "from", "what",
            "does", "show", "link", "them", "sources", "journal", "articles",
            "there", "their", "have", "been", "were", "when", "where", "which",
            "into", "then", "than", "some", "most", "many", "first", "next",
            "brief", "tour", "make", "sense", "weeks", "wave", "around",
        ]
        let terms = source.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && !stop.contains($0.lowercased()) }
        let counts = Dictionary(terms.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        let unique = Array(NSOrderedSet(array: terms.map { $0.lowercased() }))
            .compactMap { $0 as? String }
        return unique.enumerated()
            .sorted { left, right in
                let a = counts[left.element] ?? 0
                let b = counts[right.element] ?? 0
                return a == b ? left.offset < right.offset : a > b
            }
            .prefix(7)
            .map(\.element)
            .joined(separator: " ")
    }
}

actor PaperSearch {
    static let shared = PaperSearch()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private struct OpenAlexResponse: Decodable {
        struct Work: Decodable {
            struct Authorship: Decodable {
                struct Author: Decodable { let display_name: String? }
                let author: Author?
            }
            let display_name: String
            let doi: String?
            let publication_year: Int?
            let authorships: [Authorship]?
        }
        let results: [Work]
    }

    private struct CrossrefResponse: Decodable {
        struct Work: Decodable {
            struct Author: Decodable {
                let given: String?
                let family: String?
            }
            struct Published: Decodable {
                let dateParts: [[Int]]
                enum CodingKeys: String, CodingKey { case dateParts = "date-parts" }
            }
            let DOI: String
            let title: [String]?
            let author: [Author]?
            let published: Published?
        }
        let message: Work
    }

    private struct ConfirmedPaper {
        let title: String
        let authors: String
        let year: Int?
    }

    func search(query: String) async throws -> [PaperResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        var components = URLComponents(string: "https://api.openalex.org/works")!
        components.queryItems = [
            .init(name: "search", value: query),
            .init(name: "per_page", value: "10"),
            .init(name: "select", value: "display_name,doi,publication_year,authorships"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(status)
        else { throw AIError.requestFailed("Paper search is unavailable. Try again shortly.") }
        let works = try JSONDecoder().decode(OpenAlexResponse.self, from: data).results

        var results: [PaperResult] = []
        for work in works {
            guard results.count < 5,
                  let rawDOI = work.doi,
                  let doi = Self.normalizedDOI(rawDOI),
                  !results.contains(where: { $0.doi == doi }),
                  let confirmed = try? await confirm(doi: doi, title: work.display_name)
            else { continue }
            guard let landingURL = URL(string: "https://doi.org/\(doi)") else { continue }
            results.append(PaperResult(
                doi: doi,
                title: confirmed.title,
                authors: confirmed.authors,
                year: confirmed.year,
                landingURL: landingURL,
                metadataVerified: true
            ))
        }
        return results
    }

    private func confirm(doi: String, title: String) async throws -> ConfirmedPaper? {
        guard let escaped = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.crossref.org/works/\(escaped)")
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let work = try? JSONDecoder().decode(CrossrefResponse.self, from: data).message,
              work.DOI.caseInsensitiveCompare(doi) == .orderedSame,
              let confirmed = work.title?.first,
              Self.titleMatches(title, confirmed)
        else { return nil }
        let authors = (work.author ?? []).prefix(3).map { author in
            [author.given, author.family].compactMap { $0 }.joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: ", ")
        return ConfirmedPaper(
            title: confirmed,
            authors: authors.isEmpty ? "Authors not listed" : authors,
            year: work.published?.dateParts.first?.first
        )
    }

    static func normalizedDOI(_ value: String) -> String? {
        let doi = value.replacingOccurrences(
            of: "https://doi.org/", with: "", options: .caseInsensitive
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return doi.hasPrefix("10.") && doi.contains("/") ? doi : nil
    }

    static func titleMatches(_ first: String, _ second: String) -> Bool {
        let a = Set(first.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let b = Set(second.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count)) >= 0.7
    }
}
