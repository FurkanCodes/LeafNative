import Accelerate
import CryptoKit
import Foundation
import NaturalLanguage
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

/// A retrievable slice of a document. Chunks overlap slightly and break on
/// sentence or word boundaries so a passage is never cut mid-thought.
struct ResearchChunk: Sendable, Equatable {
    let locator: String
    let text: String
    let pageIndex: Int?
    let offset: Int?
    let termCounts: [String: Int]
    let termTotal: Int
}

actor ResearchIndex {
    static let shared = ResearchIndex()

    static let maxPassages = 5
    static let chunkLength = 1_200
    static let chunkOverlap = 200
    /// Chunks with no shared keywords still qualify above this cosine similarity.
    static let semanticOnlyThreshold = 0.3
    private static let vectorFormatVersion = 1

    private struct Entry {
        let chunks: [ResearchChunk]
        let documentFrequency: [String: Int]
        let averageLength: Double
        let language: NLLanguage?
        /// Short sentence windows embedded separately so one relevant
        /// sentence isn't diluted by the rest of its chunk.
        let segments: [String]
        let segmentOwners: [Int]
        var vectors: EmbeddingMatrix?
    }

    private var cache: [String: Entry] = [:]
    private var embeddingBuilds: [String: Task<Void, Never>] = [:]
    private var queryEmbeddings: [NLLanguage: NLEmbedding] = [:]
    private let vectorDirectory: URL?

    init(vectorDirectory: URL? = ResearchIndex.defaultVectorDirectory()) {
        self.vectorDirectory = vectorDirectory
    }

    /// Chunks the document and starts building semantic vectors in the
    /// background, so they are usually ready by the first question.
    func prepare(
        bookID: UUID,
        contentHash: String,
        format: ReaderFormat,
        url: URL?,
        extractedText: String?
    ) {
        _ = entry(bookID: bookID, contentHash: contentHash, format: format, url: url, text: extractedText)
    }

    func search(
        bookID: UUID,
        contentHash: String,
        format: ReaderFormat,
        url: URL?,
        extractedText: String?,
        question: String,
        selected: IndexedPassage?,
        contents: [BookContentEntry] = [],
        semanticWait: Duration = .seconds(2)
    ) async -> [PassageCitation] {
        let key = cacheKey(bookID: bookID, contentHash: contentHash)
        var index = entry(bookID: bookID, contentHash: contentHash, format: format, url: url, text: extractedText)

        let words = Self.terms(question)
        if words.isEmpty, let selected, !selected.text.isEmpty {
            return [PassageCitation(
                id: "S1", locator: selected.locator, quote: selected.text,
                label: selected.label, contentHash: contentHash
            )]
        }

        if index.vectors == nil, let build = embeddingBuilds[key] {
            await Self.wait(for: build, atMost: semanticWait)
            index = cache[key] ?? index
        }
        let similarities = semanticSimilarities(question: question, index: index)
        let keywordScores = index.chunks.map { Self.bm25(words, chunk: $0, index: index) }
        let bestKeyword = keywordScores.max() ?? 0

        var ranked: [(score: Double, position: Int)] = []
        for position in index.chunks.indices {
            let keyword = bestKeyword > 0 ? keywordScores[position] / bestKeyword : 0
            let cosine = similarities?[position] ?? 0
            guard keyword > 0 || cosine >= Self.semanticOnlyThreshold else { continue }
            let score = similarities == nil
                ? keyword
                : 0.55 * keyword + 0.45 * min(1, max(0, (cosine - 0.1) / 0.4))
            ranked.append((score, position))
        }
        ranked.sort { $0.score == $1.score ? $0.position < $1.position : $0.score > $1.score }

        var passages: [IndexedPassage] = []
        if let selected, !selected.text.isEmpty { passages.append(selected) }
        for (_, position) in ranked where passages.count < Self.maxPassages {
            let chunk = index.chunks[position]
            let passage = IndexedPassage(
                locator: chunk.locator,
                label: Self.label(for: chunk, contents: contents),
                text: chunk.text
            )
            if !passages.contains(where: { $0.locator == passage.locator && $0.text == passage.text }) {
                passages.append(passage)
            }
        }
        return passages.enumerated().map { number, passage in
            PassageCitation(
                id: "S\(number + 1)",
                locator: passage.locator,
                quote: passage.text,
                label: passage.label,
                contentHash: contentHash
            )
        }
    }

    func clear(bookID: UUID) {
        for (key, build) in embeddingBuilds where key.hasPrefix(bookID.uuidString) {
            build.cancel()
        }
        embeddingBuilds = embeddingBuilds.filter { !$0.key.hasPrefix(bookID.uuidString) }
        cache = cache.filter { !$0.key.hasPrefix(bookID.uuidString) }
    }

    // MARK: - Index construction

    private func cacheKey(bookID: UUID, contentHash: String) -> String {
        "\(bookID.uuidString):\(contentHash)"
    }

    private func entry(
        bookID: UUID,
        contentHash: String,
        format: ReaderFormat,
        url: URL?,
        text: String?
    ) -> Entry {
        let key = cacheKey(bookID: bookID, contentHash: contentHash)
        if let cached = cache[key] { return cached }

        let chunks = Self.extract(format: format, url: url, text: text)
        var frequency: [String: Int] = [:]
        for chunk in chunks {
            for term in chunk.termCounts.keys { frequency[term, default: 0] += 1 }
        }
        let totalLength = chunks.reduce(0) { $0 + $1.termTotal }
        let language = Self.language(of: chunks)
        var segments: [String] = []
        var owners: [Int] = []
        for (position, chunk) in chunks.enumerated() {
            for segment in Self.sentenceWindows(chunk.text) {
                segments.append(segment)
                owners.append(position)
            }
        }
        let entry = Entry(
            chunks: chunks,
            documentFrequency: frequency,
            averageLength: chunks.isEmpty ? 1 : max(1, Double(totalLength) / Double(chunks.count)),
            language: language,
            segments: segments,
            segmentOwners: owners,
            vectors: nil
        )
        cache[key] = entry
        startEmbeddingBuild(key: key, contentHash: contentHash, segments: segments, language: language)
        return entry
    }

    private func startEmbeddingBuild(
        key: String,
        contentHash: String,
        segments: [String],
        language: NLLanguage?
    ) {
        guard let language, !segments.isEmpty, embeddingBuilds[key] == nil,
              NLEmbedding.sentenceEmbedding(for: language) != nil
        else { return }
        let file = vectorDirectory?.appendingPathComponent(
            "\(contentHash)-v\(Self.vectorFormatVersion)-\(language.rawValue).vectors"
        )
        let texts = segments
        embeddingBuilds[key] = Task.detached(priority: .utility) { [weak self] in
            guard let vectors = await Self.embed(texts, language: language, cachedAt: file) else { return }
            await self?.didEmbed(key: key, vectors: vectors)
        }
    }

    private func didEmbed(key: String, vectors: EmbeddingMatrix) {
        guard var entry = cache[key], entry.segments.count == vectors.rows else { return }
        entry.vectors = vectors
        cache[key] = entry
    }

    private static func embed(_ texts: [String], language: NLLanguage, cachedAt file: URL?) async -> EmbeddingMatrix? {
        if let file, let stored = ResearchVectorStore.read(file), stored.rows == texts.count {
            return stored
        }
        guard let dimension = NLEmbedding.sentenceEmbedding(for: language)?.dimension else { return nil }
        let cancelled = CancellationFlag()
        let values = await withTaskCancellationHandler {
            // Each worker embeds an interleaved stripe with its own NLEmbedding
            // instance, leaving a core or two free for the reader.
            let workers = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
            var values = [Float](repeating: 0, count: texts.count * dimension)
            values.withUnsafeMutableBufferPointer { output in
                nonisolated(unsafe) let output = output
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return }
                    for row in stride(from: worker, to: texts.count, by: workers) {
                        if cancelled.isSet { return }
                        guard let vector = embedding.vector(for: texts[row]), vector.count == dimension
                        else { continue }
                        for (column, value) in normalized(vector.map(Float.init)).enumerated() {
                            output[row * dimension + column] = value
                        }
                    }
                }
            }
            return values
        } onCancel: {
            cancelled.set()
        }
        guard !cancelled.isSet else { return nil }
        let matrix = EmbeddingMatrix(rows: texts.count, dimension: dimension, values: values)
        if let file { ResearchVectorStore.write(matrix, to: file) }
        return matrix
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private func semanticSimilarities(question: String, index: Entry) -> [Double]? {
        guard let vectors = index.vectors, vectors.rows == index.segmentOwners.count,
              let language = index.language
        else { return nil }
        if queryEmbeddings[language] == nil {
            queryEmbeddings[language] = NLEmbedding.sentenceEmbedding(for: language)
        }
        guard let raw = queryEmbeddings[language]?.vector(for: question) else { return nil }
        let query = Self.normalized(raw.map(Float.init))
        guard query.count == vectors.dimension else { return nil }
        var scores = [Float](repeating: 0, count: vectors.rows)
        cblas_sgemv(
            CblasRowMajor, CblasNoTrans, Int32(vectors.rows), Int32(vectors.dimension),
            1, vectors.values, Int32(vectors.dimension), query, 1, 0, &scores, 1
        )
        var best = Array(repeating: -1.0, count: index.chunks.count)
        for (score, owner) in zip(scores, index.segmentOwners) {
            best[owner] = max(best[owner], Double(score))
        }
        return best
    }

    private static func wait(for build: Task<Void, Never>, atMost limit: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await build.value }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    static func defaultVectorDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Leaf", isDirectory: true)
            .appendingPathComponent("ResearchIndex", isDirectory: true)
    }

    // MARK: - Chunking

    static func extract(format: ReaderFormat, url: URL?, text: String?) -> [ResearchChunk] {
        if format == .pdf, let url, let document = PDFDocument(url: url) {
            return (0..<document.pageCount).flatMap { pageIndex -> [ResearchChunk] in
                guard let pageText = document.page(at: pageIndex)?.string else { return [] }
                return chunks(pageText).map { range, fragment in
                    chunk(locator: "pdf:\(pageIndex)", text: fragment, pageIndex: pageIndex, offset: nil)
                }
            }
        }
        guard let text, !text.isEmpty else { return [] }
        return chunks(text).map { range, fragment in
            chunk(
                locator: "text:\(range.location):\(range.length)",
                text: fragment, pageIndex: nil, offset: range.location
            )
        }
    }

    private static func chunk(locator: String, text: String, pageIndex: Int?, offset: Int?) -> ResearchChunk {
        let words = stemmedWords(text)
        var counts: [String: Int] = [:]
        for word in words { counts[word, default: 0] += 1 }
        return ResearchChunk(
            locator: locator, text: text, pageIndex: pageIndex, offset: offset,
            termCounts: counts, termTotal: words.count
        )
    }

    /// Splits text into ~`chunkLength` UTF-16 ranges that end at a sentence or
    /// word boundary and overlap by roughly `chunkOverlap`.
    static func chunks(_ text: String) -> [(NSRange, String)] {
        let value = text as NSString
        let total = value.length
        var result: [(NSRange, String)] = []
        var start = 0
        while start < total {
            var end = min(start + chunkLength, total)
            if end < total {
                end = boundary(in: value, from: start + chunkLength * 2 / 3, to: end) ?? end
            }
            let range = NSRange(location: start, length: end - start)
            let fragment = value.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !fragment.isEmpty { result.append((range, fragment)) }
            guard end < total else { break }
            var next = max(start + 1, end - chunkOverlap)
            while next < end, !isWhitespace(value.character(at: next - 1)) { next += 1 }
            start = next
        }
        return result
    }

    private static func boundary(in value: NSString, from lower: Int, to upper: Int) -> Int? {
        var wordBreak: Int?
        var position = upper
        while position > lower {
            let previous = value.character(at: position - 1)
            if previous == 0x0A { return position }
            if isWhitespace(previous) {
                if position >= 2, [0x2E, 0x3F, 0x21].contains(value.character(at: position - 2)) {
                    return position
                }
                wordBreak = wordBreak ?? position
            }
            position -= 1
        }
        return wordBreak
    }

    /// Groups consecutive sentences into windows of roughly 80–400 characters, merging only fragments.
    static func sentenceWindows(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var windows: [String] = []
        var current = ""
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }
            if !current.isEmpty, current.count + sentence.count > 400 {
                windows.append(current)
                current = ""
            }
            current += current.isEmpty ? sentence : " " + sentence
            if current.count >= 80 {
                windows.append(current)
                current = ""
            }
            return true
        }
        if !current.isEmpty { windows.append(current) }
        return windows
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x0D || unit == 0x09
    }

    // MARK: - Scoring

    private static func bm25(_ query: Set<String>, chunk: ResearchChunk, index: Entry) -> Double {
        let count = Double(index.chunks.count)
        let lengthRatio = Double(chunk.termTotal) / index.averageLength
        return query.reduce(0) { score, term in
            guard let frequency = chunk.termCounts[term] else { return score }
            let documents = Double(index.documentFrequency[term] ?? 0)
            let idf = log(1 + (count - documents + 0.5) / (documents + 0.5))
            let tf = Double(frequency)
            return score + idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * lengthRatio))
        }
    }

    private static func label(for chunk: ResearchChunk, contents: [BookContentEntry]) -> String {
        if let page = chunk.pageIndex {
            let section = contents.last { ($0.pdfPageIndex ?? .max) <= page }?.title
            return section.map { "Page \(page + 1) · \($0)" } ?? "Page \(page + 1)"
        }
        if let offset = chunk.offset,
           let section = contents.last(where: { ($0.textOffset ?? .max) <= offset })?.title,
           !section.isEmpty {
            return section
        }
        return "Document"
    }

    private static func language(of chunks: [ResearchChunk]) -> NLLanguage? {
        let sample = chunks.prefix(8).map(\.text).joined(separator: " ")
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(4_000)))
        return recognizer.dominantLanguage
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? vector.map { $0 / length } : vector
    }

    // MARK: - Terms

    private static let stopWords: Set<String> = ["about", "after", "and", "are", "can", "excerpt", "for", "from", "how", "into", "me", "related", "that", "the", "this", "what", "when", "where", "which", "why", "with", "would", "could", "should", "their", "there", "these", "those", "paper", "papers", "study", "studies", "research", "find", "show", "does", "have", "book", "page", "passage", "section", "summarize", "tell", "you"]

    static func terms(_ text: String) -> Set<String> {
        Set(stemmedWords(text))
    }

    private static func stemmedWords(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
            .map(stem)
    }

    private static let suffixes = [
        "izations", "ization", "ational", "ations", "ation", "ating", "ated", "ates", "ate",
        "ities", "ity", "ingly", "ings", "ing", "edly", "ed", "ments", "ment", "ness", "ly",
    ]

    /// A deliberately small English stemmer: enough to match "consolidating",
    /// "consolidated", and "consolidation", or "memory" and "memories".
    static func stem(_ word: String) -> String {
        guard word.count > 4, word.allSatisfy(\.isLetter) else { return word }
        var result = word
        if result.hasSuffix("sses") {
            result.removeLast(2)
        } else if result.hasSuffix("ies") {
            result.removeLast(2)
        } else if result.hasSuffix("s"), !["ss", "us", "is"].contains(where: result.hasSuffix) {
            result.removeLast()
        }
        for suffix in suffixes where result.hasSuffix(suffix) && result.count - suffix.count >= 4 {
            result.removeLast(suffix.count)
            break
        }
        if result.hasSuffix("y") {
            result.removeLast()
            result.append("i")
        } else if result.hasSuffix("e"), result.count > 4 {
            result.removeLast()
        }
        return result
    }
}

/// Row-major, L2-normalized embedding vectors.
struct EmbeddingMatrix: Sendable, Equatable {
    let rows: Int
    let dimension: Int
    let values: [Float]
}

enum ResearchVectorStore {
    private static let magic: UInt32 = 0x4C46_5631 // "LFV1"

    static func read(_ url: URL) -> EmbeddingMatrix? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 12 else { return nil }
        return data.withUnsafeBytes { raw -> EmbeddingMatrix? in
            let fileMagic = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let rows = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            let dimension = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            guard fileMagic == magic, data.count == 12 + rows * dimension * 4 else { return nil }
            let values = [Float](unsafeUninitializedCapacity: rows * dimension) { buffer, count in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[12...]))
                count = rows * dimension
            }
            return EmbeddingMatrix(rows: rows, dimension: dimension, values: values)
        }
    }

    static func write(_ matrix: EmbeddingMatrix, to url: URL) {
        guard matrix.values.count == matrix.rows * matrix.dimension else { return }
        var data = Data()
        for value in [magic, UInt32(matrix.rows), UInt32(matrix.dimension)] {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        matrix.values.withUnsafeBytes { data.append(contentsOf: $0) }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
