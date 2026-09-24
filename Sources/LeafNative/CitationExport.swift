import Foundation
import PDFKit

struct CitationAuthor: Codable, Equatable, Sendable {
    var given: String
    var family: String

    /// Splits a display name such as "Robert M. Sapolsky" or "Sapolsky, Robert".
    init(displayName: String) {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = name.firstIndex(of: ",") {
            family = String(name[..<comma]).trimmingCharacters(in: .whitespaces)
            given = String(name[name.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        } else if let space = name.lastIndex(of: " ") {
            given = String(name[..<space]).trimmingCharacters(in: .whitespaces)
            family = String(name[name.index(after: space)...])
        } else {
            given = ""
            family = name
        }
    }

    init(given: String, family: String) {
        self.given = given
        self.family = family
    }

    var displayName: String {
        [given, family].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct CitationMetadata: Codable, Equatable, Sendable {
    var doi: String?
    /// Crossref work type, e.g. "journal-article", "book", "book-chapter".
    var type: String
    var title: String
    var authors: [CitationAuthor]
    var year: Int?
    var container: String?
    var publisher: String?
    var volume: String?
    var issue: String?
    var pages: String?

    /// Metadata built only from the library record, used when no DOI resolves.
    static func fallback(title: String, author: String, format: ReaderFormat) -> CitationMetadata {
        let separators = [";", " & ", " and "]
        var names = [author]
        for separator in separators {
            names = names.flatMap { $0.components(separatedBy: separator) }
        }
        let authors = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare("Unknown Author") != .orderedSame }
            .map(CitationAuthor.init(displayName:))
        let bookLike: Set<ReaderFormat> = [.epub, .mobi, .azw, .azw3, .fb2]
        return CitationMetadata(
            doi: nil,
            type: bookLike.contains(format) ? "book" : "document",
            title: title,
            authors: authors
        )
    }

    init(
        doi: String? = nil, type: String, title: String, authors: [CitationAuthor],
        year: Int? = nil, container: String? = nil, publisher: String? = nil,
        volume: String? = nil, issue: String? = nil, pages: String? = nil
    ) {
        self.doi = doi
        self.type = type
        self.title = title
        self.authors = authors
        self.year = year
        self.container = container
        self.publisher = publisher
        self.volume = volume
        self.issue = issue
        self.pages = pages
    }
}

// MARK: - DOI discovery

enum DOIDetector {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b10\.\d{4,9}/[^\s"<>]+"#
    )

    /// All DOIs in `text`, in order of appearance, normalized and de-duplicated.
    static func all(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var seen: [String] = []
        for match in pattern.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            var doi = String(text[swiftRange])
            while let last = doi.last, ".,;:)]}'".contains(last) {
                // Keep a closing parenthesis only when it balances one inside the DOI.
                if last == ")", doi.filter({ $0 == "(" }).count >= doi.filter({ $0 == ")" }).count { break }
                doi.removeLast()
            }
            doi = doi.lowercased()
            if !seen.contains(doi) { seen.append(doi) }
        }
        return seen
    }

    /// Text most likely to contain the work's own DOI: PDF metadata plus the
    /// first pages, or the opening of a reflowable document.
    static func candidateText(format: ReaderFormat, url: URL?, text: String?) -> String {
        if format == .pdf, let url, let document = PDFDocument(url: url) {
            let attributes = document.documentAttributes ?? [:]
            let metadata = [PDFDocumentAttribute.subjectAttribute, .keywordsAttribute, .titleAttribute]
                .compactMap { attributes[$0] }
                .map { ($0 as? [Any])?.map { "\($0)" }.joined(separator: " ") ?? "\($0)" }
            let pages = (0..<min(2, document.pageCount)).compactMap { document.page(at: $0)?.string }
            return (metadata + pages).joined(separator: "\n")
        }
        return String((text ?? "").prefix(20_000))
    }

    /// Whether most words of `title` appear in `text`. Guards against picking
    /// up a DOI that belongs to a cited reference rather than the work itself.
    static func titleAppears(_ title: String, in text: String) -> Bool {
        let words = { (value: String) in
            Set(value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init).filter { $0.count > 3 })
        }
        let titleWords = words(title)
        guard !titleWords.isEmpty else { return false }
        let found = titleWords.intersection(words(text)).count
        return Double(found) / Double(titleWords.count) >= 0.8
    }
}

// MARK: - Crossref

struct CrossrefMetadataClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func metadata(doi: String) async throws -> CitationMetadata? {
        guard let doi = PaperSearch.normalizedDOI(doi),
              let escaped = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.crossref.org/works/\(escaped)")
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(
            "LeafNative (https://github.com/FurkanCodes/LeafNative)",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw AIError.badResponse
        }
        if status == 404 { return try await registryMetadata(doi: doi) }
        guard (200..<300).contains(status) else {
            throw AIError.requestFailed("Crossref is unavailable. Try again shortly.")
        }
        return Self.parse(data)
    }

    /// DOIs registered outside Crossref, such as arXiv's DataCite DOIs, resolve
    /// through doi.org content negotiation as CSL-JSON.
    private func registryMetadata(doi: String) async throws -> CitationMetadata? {
        guard let escaped = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://doi.org/\(escaped)")
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.citationstyles.csl+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw AIError.badResponse
        }
        if status == 404 { return nil }
        guard (200..<300).contains(status) else {
            throw AIError.requestFailed("The DOI registry is unavailable. Try again shortly.")
        }
        return Self.parseCSL(data)
    }

    static func parseCSL(_ data: Data) -> CitationMetadata? {
        guard let work = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = firstString(work["title"]), !title.isEmpty
        else { return nil }
        let types = [
            "article-journal": "journal-article", "chapter": "book-chapter",
            "paper-conference": "proceedings-article", "book": "book", "thesis": "dissertation",
            "report": "report", "article": "posted-content",
        ]
        let people = (work["author"] as? [[String: Any]]) ?? (work["editor"] as? [[String: Any]]) ?? []
        let authors = people.compactMap { person -> CitationAuthor? in
            if let family = person["family"] as? String, !family.isEmpty {
                return CitationAuthor(given: person["given"] as? String ?? "", family: family)
            }
            return (person["literal"] as? String ?? person["name"] as? String)
                .map { CitationAuthor(given: "", family: $0) }
        }
        let dates = (work["issued"] as? [String: Any])?["date-parts"] as? [[Any]]
        let year = (dates?.first?.first as? Int) ?? Int("\(dates?.first?.first ?? "")")
        return CitationMetadata(
            doi: (work["DOI"] as? String)?.lowercased(),
            type: (work["type"] as? String).flatMap { types[$0] } ?? "document",
            title: collapse(title),
            authors: authors,
            year: year,
            container: firstString(work["container-title"]),
            publisher: firstString(work["publisher"]),
            volume: firstString(work["volume"]),
            issue: firstString(work["issue"]),
            pages: firstString(work["page"])
        )
    }

    private static func firstString(_ value: Any?) -> String? {
        let raw: String? = switch value {
        case let string as String: string
        case let strings as [String]: strings.first
        case let number as NSNumber: number.stringValue
        default: nil
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func collapse(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func parse(_ data: Data) -> CitationMetadata? {
        struct Envelope: Decodable { let message: Work }
        struct Work: Decodable {
            let DOI: String
            let type: String?
            let title: [String]?
            let author: [Author]?
            let editor: [Author]?
            let issued: DateParts?
            let published: DateParts?
            let containerTitle: [String]?
            let publisher: String?
            let volume: String?
            let issue: String?
            let page: String?

            enum CodingKeys: String, CodingKey {
                case DOI, type, title, author, editor, issued, published, publisher, volume, issue, page
                case containerTitle = "container-title"
            }
        }
        struct Author: Decodable {
            let given: String?
            let family: String?
            let name: String?
        }
        struct DateParts: Decodable {
            let dateParts: [[Int?]]?
            enum CodingKeys: String, CodingKey { case dateParts = "date-parts" }
        }

        guard let work = try? JSONDecoder().decode(Envelope.self, from: data).message,
              let title = work.title?.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        let people = (work.author?.isEmpty == false ? work.author : work.editor) ?? []
        let authors = people.compactMap { person -> CitationAuthor? in
            if let family = person.family, !family.isEmpty {
                return CitationAuthor(given: person.given ?? "", family: family)
            }
            return person.name.map { CitationAuthor(given: "", family: $0) }
        }
        let year = (work.issued?.dateParts ?? work.published?.dateParts)?.first?.first ?? nil
        let clean = { (value: String?) -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
            else { return nil }
            return value
        }
        // Chapters list the series first ("Lecture Notes in Computer Science")
        // and the volume or proceedings title last.
        let type = work.type ?? "document"
        let containers = work.containerTitle ?? []
        let container = ["book-chapter", "book-section", "book-part", "proceedings-article"].contains(type)
            ? containers.last : containers.first
        return CitationMetadata(
            doi: work.DOI.lowercased(),
            type: type,
            title: collapse(title),
            authors: authors,
            year: year,
            container: clean(container),
            publisher: clean(work.publisher),
            volume: clean(work.volume),
            issue: clean(work.issue),
            pages: clean(work.page)
        )
    }
}

// MARK: - Formatting

enum CitationFormatter {
    private static let skippedTitleWords: Set<String> = ["a", "an", "the", "on", "of", "in", "and", "for", "to"]

    static func citeKey(_ citation: CitationMetadata) -> String {
        let ascii = { (value: String) in
            value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
                .lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
        let family = citation.authors.first.map { ascii($0.family) } ?? ""
        let word = citation.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { ascii(String($0)) }
            .first { !$0.isEmpty && !skippedTitleWords.contains($0) } ?? ""
        let key = family + (citation.year.map(String.init) ?? "") + word
        return key.isEmpty ? "leaf" : key
    }

    static func bibTeX(_ citation: CitationMetadata) -> String {
        let entryType: String
        var fields: [(String, String)] = []
        switch citation.type {
        case "journal-article":
            entryType = "article"
            citation.container.map { fields.append(("journal", $0)) }
        case "book", "monograph", "edited-book", "reference-book":
            entryType = "book"
        case "book-chapter", "book-section", "book-part":
            entryType = "incollection"
            citation.container.map { fields.append(("booktitle", $0)) }
        case "proceedings-article":
            entryType = "inproceedings"
            citation.container.map { fields.append(("booktitle", $0)) }
        case "dissertation":
            entryType = "phdthesis"
        case "report":
            entryType = "techreport"
        default:
            entryType = "misc"
            citation.container.map { fields.append(("howpublished", $0)) }
        }
        var ordered: [(String, String)] = []
        if !citation.authors.isEmpty {
            ordered.append(("author", citation.authors.map { author in
                author.given.isEmpty ? "{\(author.family)}" : "\(author.family), \(author.given)"
            }.joined(separator: " and ")))
        }
        // Double braces preserve the title's capitalization in BibTeX styles.
        ordered.append(("title", "{\(escape(citation.title))}"))
        ordered += fields.map { ($0.0, escape($0.1)) }
        citation.year.map { ordered.append(("year", String($0))) }
        citation.volume.map { ordered.append(("volume", $0)) }
        citation.issue.map { ordered.append(("number", $0)) }
        citation.pages.map {
            ordered.append(("pages", $0.replacingOccurrences(of: #"\s*[-–]+\s*"#, with: "--", options: .regularExpression)))
        }
        citation.publisher.map { ordered.append(("publisher", escape($0))) }
        citation.doi.map { ordered.append(("doi", $0)) }
        let body = ordered.map { "  \($0.0) = {\($0.1)}" }.joined(separator: ",\n")
        return "@\(entryType){\(citeKey(citation)),\n\(body)\n}"
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        for character in value {
            if "&%$#_".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// An APA 7 reference. With `markdown`, titles of standalone works and
    /// journal names are italicized.
    static func apa(_ citation: CitationMetadata, markdown: Bool = false) -> String {
        let italic = { (value: String) in markdown ? "*\(value)*" : value }
        let year = "(\(citation.year.map(String.init) ?? "n.d."))."
        let title = citation.title.hasSuffix("?") || citation.title.hasSuffix("!")
            ? citation.title : citation.title + "."
        let standalone = !["journal-article", "book-chapter", "proceedings-article"].contains(citation.type)

        var parts: [String] = []
        if citation.authors.isEmpty {
            parts.append(standalone ? italic(title) : title)
            parts.append(year)
        } else {
            let authors = apaAuthors(citation.authors)
            parts.append(authors.hasSuffix(".") ? authors : authors + ".")
            parts.append(year)
            parts.append(standalone ? italic(title) : title)
        }
        if citation.type == "journal-article", let journal = citation.container {
            var source = italic(journal)
            if let volume = citation.volume {
                source += ", " + italic(volume)
                if let issue = citation.issue { source += "(\(issue))" }
            }
            if let pages = citation.pages {
                source += ", " + pages.replacingOccurrences(of: "-", with: "–")
            }
            parts.append(source + ".")
        } else if let container = citation.container, !standalone {
            parts.append("In \(italic(container)).")
        }
        if citation.type != "journal-article", let publisher = citation.publisher {
            parts.append(publisher + ".")
        }
        if let doi = citation.doi {
            parts.append("https://doi.org/\(doi)")
        }
        return parts.joined(separator: " ")
    }

    private static func apaAuthors(_ authors: [CitationAuthor]) -> String {
        let formatted = authors.map { author -> String in
            let initials = author.given
                .split(whereSeparator: { $0 == " " || $0 == "." })
                .map { part in
                    part.split(separator: "-").compactMap(\.first).map { "\($0)." }.joined(separator: "-")
                }
                .joined(separator: " ")
            return initials.isEmpty ? author.family : "\(author.family), \(initials)"
        }
        if formatted.count == 1 { return formatted[0] }
        if formatted.count > 20 {
            return formatted.prefix(19).joined(separator: ", ") + ", … " + formatted.last!
        }
        return formatted.dropLast().joined(separator: ", ") + ", & " + formatted.last!
    }

    /// A parenthetical APA citation, e.g. "(Sapolsky, 2017, p. 12)".
    static func inText(_ citation: CitationMetadata, page: Int? = nil) -> String {
        let names: String
        switch citation.authors.count {
        case 0: names = citation.title
        case 1: names = citation.authors[0].family
        case 2: names = "\(citation.authors[0].family) & \(citation.authors[1].family)"
        default: names = "\(citation.authors[0].family) et al."
        }
        var parts = [names, citation.year.map(String.init) ?? "n.d."]
        if let page { parts.append("p. \(page)") }
        return "(" + parts.joined(separator: ", ") + ")"
    }

    static func quote(_ text: String, citation: CitationMetadata, page: Int?) -> String {
        "“\(text.trimmingCharacters(in: .whitespacesAndNewlines))” \(inText(citation, page: page))"
    }
}

// MARK: - Markdown notes

struct ExportedHighlight: Sendable, Equatable {
    var quote: String
    var note: String
    var color: HighlightColor
    var locator: String
    var chapter: String
    var createdAt: Date

    /// One-based PDF page number, when the highlight is in a PDF.
    var page: Int? { AnnotationLocation.page(locator) }

    fileprivate var position: (Int, Int) { AnnotationLocation.position(locator) }
}

enum NotesMarkdown {
    static let placeholderChapters: Set<String> = ["", "Start reading"]

    static func document(
        citation: CitationMetadata,
        highlights: [ExportedHighlight],
        exportedAt: Date = .now
    ) -> String {
        let key = CitationFormatter.citeKey(citation)
        let ordered = highlights.filter {
            !$0.quote.isEmpty || !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { left, right in
            left.position == right.position ? left.createdAt < right.createdAt : left.position < right.position
        }

        var lines = ["---", "title: \(yaml(citation.title))"]
        if !citation.authors.isEmpty {
            lines.append("authors:")
            lines += citation.authors.map { "  - \(yaml($0.displayName))" }
        }
        citation.year.map { lines.append("year: \($0)") }
        citation.doi.map { lines.append("doi: \(yaml($0))") }
        lines.append("citekey: \(key)")
        lines.append("highlights: \(ordered.filter { !$0.quote.isEmpty }.count)")
        lines.append("exported: \(exportedAt.formatted(.iso8601.year().month().day()))")
        lines.append("source: Leaf Native")
        lines += ["---", "", "# \(citation.title)", "", CitationFormatter.apa(citation, markdown: true)]

        var currentChapter: String?
        for highlight in ordered {
            let chapter = highlight.chapter.trimmingCharacters(in: .whitespacesAndNewlines)
            if !placeholderChapters.contains(chapter), chapter != currentChapter {
                lines += ["", "## \(chapter)"]
                currentChapter = chapter
            }
            lines.append("")
            let pandoc = highlight.page.map { "[@\(key), p. \($0)]" } ?? "[@\(key)]"
            let note = highlight.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if highlight.quote.isEmpty {
                // A page note: the reader's own words, anchored to a location.
                let location = highlight.page.map { " · p. \($0)" } ?? ""
                lines += ["**Note**\(location) \(pandoc)", "", note]
                continue
            }
            let quoteLines = highlight.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
            lines += quoteLines.map { $0.isEmpty ? ">" : "> \($0)" }
            var attribution = [highlight.color.displayName]
            if let page = highlight.page { attribution.insert("p. \(page)", at: 0) }
            lines += [">", "> — \(attribution.joined(separator: " · ")) \(pandoc)"]
            if !note.isEmpty { lines += ["", note] }
        }
        if ordered.isEmpty { lines += ["", "_No highlights yet._"] }
        return lines.joined(separator: "\n") + "\n"
    }

    static func fileName(for title: String, fallback: String = "Notes") -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = title.components(separatedBy: illegal).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return String((cleaned.isEmpty ? fallback : cleaned).prefix(120)) + ".md"
    }

    private static func yaml(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
