import CryptoKit
import Foundation
import PDFKit

enum ResearchContentHash {
    static func value(format: ReaderFormat, url: URL?, text: String?) -> String? {
        var hasher = SHA256()
        if format == .pdf {
            guard let url, let document = PDFDocument(url: url) else { return nil }
            var foundText = false
            for index in 0..<document.pageCount {
                guard let pageText = document.page(at: index)?.string else { continue }
                foundText = foundText || !pageText.isEmpty
                hasher.update(data: Data("page:\(index)\n".utf8))
                hasher.update(data: Data(pageText.utf8))
            }
            guard foundText else { return nil }
        } else {
            guard let text, !text.isEmpty else { return nil }
            hasher.update(data: Data(text.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct IndexedPassage: Sendable, Equatable {
    let locator: String
    let label: String
    let text: String
}

actor ResearchIndex {
    static let shared = ResearchIndex()

    private var cache: [String: [IndexedPassage]] = [:]

    func search(
        bookID: UUID,
        contentHash: String,
        format: ReaderFormat,
        url: URL?,
        extractedText: String?,
        question: String,
        selected: IndexedPassage?
    ) -> [PassageCitation] {
        let cacheKey = "\(bookID.uuidString):\(contentHash)"
        let passages: [IndexedPassage]
        if let cached = cache[cacheKey] {
            passages = cached
        } else {
            passages = Self.extract(format: format, url: url, text: extractedText)
            cache[cacheKey] = passages
        }

        let words = Self.terms(question)
        if words.isEmpty, let selected, !selected.text.isEmpty {
            return [PassageCitation(
                id: "S1", locator: selected.locator, quote: selected.text,
                label: selected.label, contentHash: contentHash
            )]
        }
        var ranked = passages.compactMap { passage -> (Int, IndexedPassage)? in
            let body = Self.terms(passage.text)
            let score = words.reduce(0) { $0 + (body.contains($1) ? 1 : 0) }
            return score > 0 ? (score, passage) : nil
        }
        ranked.sort { left, right in
            left.0 == right.0
                ? left.1.locator < right.1.locator
                : left.0 > right.0
        }

        var selectedPassages: [IndexedPassage] = []
        if let selected, !selected.text.isEmpty { selectedPassages.append(selected) }
        for (_, passage) in ranked where selectedPassages.count < 5 {
            if !selectedPassages.contains(where: { $0.locator == passage.locator }) {
                selectedPassages.append(passage)
            }
        }
        return selectedPassages.enumerated().map { index, passage in
            PassageCitation(
                id: "S\(index + 1)",
                locator: passage.locator,
                quote: passage.text,
                label: passage.label,
                contentHash: contentHash
            )
        }
    }

    func clear(bookID: UUID) {
        cache = cache.filter { !$0.key.hasPrefix(bookID.uuidString) }
    }

    private static func extract(
        format: ReaderFormat,
        url: URL?,
        text: String?
    ) -> [IndexedPassage] {
        if format == .pdf, let url, let document = PDFDocument(url: url) {
            return (0..<document.pageCount).flatMap { pageIndex -> [IndexedPassage] in
                guard let pageText = document.page(at: pageIndex)?.string else { return [] }
                return chunks(pageText, prefix: "pdf:\(pageIndex)", label: "Page \(pageIndex + 1)")
            }
        }
        guard let text, !text.isEmpty else { return [] }
        return chunks(text, prefix: "text", label: "Document")
    }

    private static func chunks(_ text: String, prefix: String, label: String) -> [IndexedPassage] {
        let value = text as NSString
        var result: [IndexedPassage] = []
        var start = 0
        while start < value.length {
            let length = min(1_200, value.length - start)
            let range = NSRange(location: start, length: length)
            let fragment = value.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !fragment.isEmpty {
                let locator = prefix == "text"
                    ? "text:\(start):\(length)" : prefix
                result.append(IndexedPassage(locator: locator, label: label, text: fragment))
            }
            start += length
        }
        return result
    }

    private static func terms(_ text: String) -> Set<String> {
        let stop: Set<String> = ["about", "after", "and", "are", "can", "excerpt", "for", "from", "how", "into", "me", "related", "that", "the", "this", "what", "when", "where", "which", "why", "with", "would", "could", "should", "their", "there", "these", "those", "paper", "papers", "study", "studies", "research", "find", "show", "does", "have", "book", "page", "passage", "section", "summarize", "tell", "you"]
        return Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 2 && !stop.contains($0) })
    }
}
