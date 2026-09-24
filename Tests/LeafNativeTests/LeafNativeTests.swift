import XCTest
import ZIPFoundation
import SwiftData
import NaturalLanguage
import AppKit
@testable import LeafNative

private final class PaperUnavailableURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class PaperMetadataURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isOpenAlex = request.url?.host == "api.openalex.org"
        let json = isOpenAlex
            ? """
              {"results":[{"display_name":"Study A","doi":"https://doi.org/10.1234/study",
                "publication_year":2024,"authorships":[],
                "best_oa_location":{"pdf_url":"https://example.org/study.pdf"},
                "abstract_inverted_index":{"study":[0],"findings":[1]}}]}
              """
            : """
              {"message":{"DOI":"10.1234/study","title":["Study A"],
                "author":[{"given":"Ada","family":"Lovelace"}],
                "published":{"date-parts":[[2024]]}}}
              """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ResearchCompanionTests: XCTestCase {
    func testCurrentPassageWinsOverWholeDocumentMatches() async {
        let index = ResearchIndex(vectorDirectory: nil)
        let selected = IndexedPassage(
            locator: "pdf:7",
            label: "Page 8",
            text: "The visible page describes childhood development."
        )
        let citations = await index.search(
            bookID: UUID(), contentHash: "original", format: .txt,
            url: nil,
            extractedText: "Neural development affects behavior. "
                + String(repeating: "Neural development is complex. ", count: 80),
            question: "What does this page say about development?",
            selected: selected
        )
        XCTAssertEqual(citations.first?.locator, "pdf:7")
        XCTAssertEqual(citations.first?.contentHash, "original")
        XCTAssertTrue(citations.dropFirst().contains { $0.locator.hasPrefix("text:") })
    }

    func testGenericPassageQuestionDoesNotPullUnrelatedPages() async {
        let index = ResearchIndex(vectorDirectory: nil)
        let selected = IndexedPassage(
            locator: "pdf:7", label: "Page 8", text: "Adult neurogenesis is discussed here."
        )
        let citations = await index.search(
            bookID: UUID(), contentHash: "original", format: .txt,
            url: nil, extractedText: "A different passage mentions related papers.",
            question: "Find papers related to this passage", selected: selected
        )
        XCTAssertEqual(citations.map(\.locator), ["pdf:7"])
    }

    func testOnlyKnownCitationIDsBecomeLinks() {
        let citation = PassageCitation(
            id: "S1", locator: "pdf:7", quote: "Evidence", label: "Page 8",
            contentHash: "original"
        )
        let rendered = ResearchCitationLinks.linkify(
            "Supported [S1], unknown [S99].", citations: [citation]
        )
        XCTAssertTrue(rendered.contains("[1](leaf-citation://S1)"))
        XCTAssertTrue(rendered.contains("[S99]"))
    }

    func testResearchSourcesMoveOutOfAnswerWithoutLosingOtherMarkdown() {
        let text = "## Findings\nUseful result.\n\n### Sources\n- [Study A](https://example.org/a)\n- [Study B](https://example.org/b)"
        let sections = ResearchSourceLinks.split(text)
        XCTAssertEqual(sections.answer, "## Findings\nUseful result.")
        XCTAssertEqual(sections.sources.map(\.title), ["Study A", "Study B"])
        XCTAssertEqual(ResearchSourceLinks.split("### Sources\n- invalid").answer, "### Sources\n- invalid")
    }

    func testPaperSearchIncludesAvailableOpenAccessPDF() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaperMetadataURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let papers = try await PaperSearch(session: session).search(query: "study")
        XCTAssertEqual(papers.count, 1)
        XCTAssertEqual(papers.first?.pdfURL?.absoluteString, "https://example.org/study.pdf")
        XCTAssertEqual(papers.first?.authors, "Ada Lovelace")
        XCTAssertEqual(papers.first?.relevanceNote, "Abstract mentions: study")
    }

    func testSavedPaperWithoutPDFFieldStillDecodes() throws {
        let json = """
            {"doi":"10.1234/study","title":"Study A","authors":"Ada Lovelace",
             "year":2024,"landingURL":"https://doi.org/10.1234/study","metadataVerified":true}
            """
        let paper = try JSONDecoder().decode(PaperResult.self, from: Data(json.utf8))
        XCTAssertNil(paper.pdfURL)
        XCTAssertNil(paper.relevanceNote)
    }

    @MainActor
    func testChangedDocumentInvalidatesPassageNavigation() throws {
        let oldHash = try XCTUnwrap(ResearchContentHash.value(
            format: .txt, url: nil, text: "First version"
        ))
        let newHash = try XCTUnwrap(ResearchContentHash.value(
            format: .txt, url: nil, text: "Revised version"
        ))
        XCTAssertNotEqual(oldHash, newHash)

        let book = BookRecord(
            title: "Draft", author: "Researcher", format: .txt,
            contentHash: "unchanged import fingerprint"
        )
        let store = ReaderStore()
        store.selectedBook = book
        store.researchContentHash = newHash
        store.navigate(to: PassageCitation(
            id: "S1", locator: "text:0:5", quote: "First", label: "Document",
            contentHash: oldHash
        ))
        XCTAssertNil(store.locationNavigation)
    }

    func testStreamingDeltasAndFailure() throws {
        var parser = AIStreamParser()
        XCTAssertEqual(try parser.consume("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}"), "Hello")
        XCTAssertEqual(try parser.consume("data: {\"type\":\"response.output_text.delta\",\"delta\":\" world\"}"), " world")
        XCTAssertThrowsError(try parser.consume(
            "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"Unavailable\"}}}"
        ))
    }

    func testPaperIntentAndMetadataValidation() {
        XCTAssertTrue(ResearchIntent.wantsPapers("Can you find studies on this passage?"))
        XCTAssertFalse(ResearchIntent.wantsPapers("Summarize this page"))
        XCTAssertEqual(PaperSearch.normalizedDOI("https://doi.org/10.1234/ABC"), "10.1234/abc")
        XCTAssertTrue(PaperSearch.titleMatches("The basics of brain development", "Basics of Brain Development, The"))
        XCTAssertFalse(PaperSearch.titleMatches("The basics of brain development", "Completely different topic"))
    }

    func testPaperQueryUsesReadingForThisPart() {
        let query = ResearchIntent.query(
            question: "Find research papers related to this part",
            selectedQuote: "Neuroplasticity changes the brain. Neuroplasticity supports learning."
        )
        XCTAssertTrue(query.contains("neuroplasticity"))
        XCTAssertFalse(query.contains("part"))
    }

    func testPaperSearchReportsServiceFailure() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaperUnavailableURLProtocol.self]
        let search = PaperSearch(session: URLSession(configuration: configuration))
        do {
            _ = try await search.search(query: "neuroplasticity")
            XCTFail("Expected a service error")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Paper search is unavailable. Try again shortly."
            )
        }
    }

    @MainActor
    func testConversationRecordsPersistInModelContainer() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: BookRecord.self, AnnotationRecord.self,
            AIThreadRecord.self, AIChatMessageRecord.self,
            configurations: configuration
        )
        let context = container.mainContext
        let bookID = UUID()
        let thread = AIThreadRecord(bookID: bookID, title: "Methods")
        context.insert(thread)
        let message = AIChatMessageRecord(
            threadID: thread.id, role: "assistant", text: "A [source].",
            contentHash: "original"
        )
        message.citations = [PassageCitation(
            id: "S1", locator: "pdf:7", quote: "Evidence",
            label: "Page 8", contentHash: "original"
        )]
        context.insert(message)
        try context.save()

        let fetchedThreads = try context.fetch(FetchDescriptor<AIThreadRecord>())
        let fetchedMessages = try context.fetch(FetchDescriptor<AIChatMessageRecord>())
        XCTAssertEqual(fetchedThreads.first?.bookID, bookID)
        XCTAssertEqual(fetchedMessages.first?.citations.first?.locator, "pdf:7")
    }
}

final class OpenAIClientTests: XCTestCase {
    func testResponsesRequestKeepsStorageDisabled() throws {
        let request = OpenAIClient.Request(
            model: "gpt-5.6-luna",
            instructions: "Help with reading",
            input: "Summarize this passage"
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(body["instructions"] as? String, "Help with reading")
        XCTAssertEqual(body["input"] as? String, "Summarize this passage")
        XCTAssertEqual(body["store"] as? Bool, false)
    }

    func testResponsesTextExtraction() throws {
        let data = Data("""
            {"output":[
              {"type":"reasoning","content":null},
              {"type":"message","content":[
                {"type":"output_text","text":"First point."},
                {"type":"output_text","text":"Second point."}
              ]}
            ]}
            """.utf8)
        let response = try JSONDecoder().decode(OpenAIClient.Response.self, from: data)
        XCTAssertEqual(response.text, "First point.\nSecond point.")
    }
}

final class ChatGPTClientTests: XCTestCase {
    func testCodexRequestStreamsWithoutStorage() throws {
        let body = ChatGPTClient.RequestBody(
            model: "gpt-5.6-luna",
            instructions: "Help with reading",
            input: [.init(role: "user", content: [.init(text: "Explain this passage")])]
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(body))
                as? [String: Any]
        )
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual(json["instructions"] as? String, "Help with reading")
    }

    func testCodexStreamText() throws {
        let events = """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"First "}

            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"point."}

            event: response.completed
            data: {"type":"response.completed","response":{"output":null}}

            """
        XCTAssertEqual(
            try ChatGPTClient.extractText(from: Data(events.utf8)),
            "First point."
        )
    }

    func testCodexStreamFailure() throws {
        let events = """
            data: {"type":"response.failed","response":{"error":{"message":"Model unavailable"}}}

            """
        XCTAssertThrowsError(
            try ChatGPTClient.extractText(from: Data(events.utf8))
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Model unavailable")
        }
    }
}

final class GeminiClientTests: XCTestCase {
    func testModelRequestIsStatelessAndUsesSelectedModel() throws {
        let client = GeminiClient(auth: .apiKey("test-key"), model: "gemini-3.8-flash")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: client.modelRequestBody(system: "Check evidence", prompt: "Summarize")
        ) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gemini-3.8-flash")
        XCTAssertEqual(body["input"] as? String, "Summarize")
        XCTAssertEqual(body["system_instruction"] as? String, "Check evidence")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
    }

    func testAPIKeyRequestHeader() async throws {
        let keyRequest = try await GeminiClient(auth: .apiKey("test-key"), model: "gemini-3.8-flash")
            .request(path: "/models?pageSize=1", method: "GET")
        XCTAssertEqual(keyRequest.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
    }

    func testInteractionsStreamAcceptsOnlyModelOutputText() throws {
        var parser = GeminiStreamParser()
        XCTAssertNil(try parser.consume("data: {\"event_type\":\"step.start\",\"index\":0,\"step\":{\"type\":\"thought\"}}"))
        XCTAssertNil(try parser.consume("data: {\"event_type\":\"step.delta\",\"index\":0,\"delta\":{\"type\":\"text\",\"text\":\"private reasoning\"}}"))
        XCTAssertNil(try parser.consume("data: {\"event_type\":\"step.start\",\"index\":1,\"step\":{\"type\":\"model_output\"}}"))
        XCTAssertEqual(try parser.consume("data: {\"event_type\":\"step.delta\",\"index\":1,\"delta\":{\"type\":\"text\",\"text\":\"Evidence\"}}"), "Evidence")
        XCTAssertNil(try parser.consume("data: {\"event_type\":\"interaction.completed\"}"))
        XCTAssertTrue(parser.receivedText)
        XCTAssertTrue(parser.completed)
    }

    func testDeepResearchReportExtraction() throws {
        let result = try GeminiInteraction.parse(Data("""
            {"id":"v1_abc","status":"completed","steps":[
              {"type":"thought","content":[{"type":"text","text":"Hidden"}]},
              {"type":"model_output","content":[{"type":"text","text":"Finding one.",
                "annotations":[{"type":"url_citation","title":"Study A","url":"https://example.org/study"}]},
                {"type":"text","text":"Finding two."}]}
            ]}
            """.utf8))
        XCTAssertEqual(result.id, "v1_abc")
        XCTAssertEqual(result.outputText, "Finding one.\n\nFinding two.\n\n### Sources\n- [Study A](https://example.org/study)")
    }
}

final class ReaderFormatTests: XCTestCase {
    func testExtensionMapping() {
        XCTAssertEqual(
            ReaderFormat(url: URL(fileURLWithPath: "/books/a.epub")),
            .epub
        )
        XCTAssertEqual(
            ReaderFormat(url: URL(fileURLWithPath: "/books/b.AZW3")),
            .azw3
        )
        XCTAssertEqual(
            ReaderFormat(url: URL(fileURLWithPath: "/books/c.kf8")),
            .azw3
        )
        XCTAssertEqual(
            ReaderFormat(url: URL(fileURLWithPath: "/books/d.markdown")),
            .markdown
        )
        XCTAssertEqual(
            ReaderFormat(url: URL(fileURLWithPath: "/books/e.xyz")),
            .unknown
        )
    }
}

final class LocatorTests: XCTestCase {
    func testTextOffset() {
        XCTAssertEqual(
            BookContentEntry(
                id: "a",
                title: "t",
                locator: "text:42:9",
                level: 0
            ).textOffset,
            42
        )
        XCTAssertNil(
            BookContentEntry(
                id: "b",
                title: "t",
                locator: "pdf:42",
                level: 0
            ).textOffset
        )
        XCTAssertNil(
            BookContentEntry(
                id: "c",
                title: "t",
                locator: "bogus",
                level: 0
            ).textOffset
        )
    }

    func testPDFPageIndex() {
        XCTAssertEqual(
            BookContentEntry(
                id: "a",
                title: "t",
                locator: "pdf:7",
                level: 0
            ).pdfPageIndex,
            7
        )
        XCTAssertNil(
            BookContentEntry(
                id: "b",
                title: "t",
                locator: "text:7:2",
                level: 0
            ).pdfPageIndex
        )
    }
}

final class ContentLoaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LeafNativeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeArchive(
        _ name: String,
        entries: [(path: String, contents: String)]
    ) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries {
            let data = Data(entry.contents.utf8)
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(data.count)
            ) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        return url
    }

    private func makeFile(_ name: String, contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testEPUBSpineOrderAndNavTOC() throws {
        let container = """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """
        let opf = """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest>
                <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
                <item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
              </manifest>
              <spine>
                <itemref idref="b"/>
                <itemref idref="a"/>
              </spine>
            </package>
            """
        let nav = """
            <?xml version="1.0"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
              <body>
                <nav epub:type="toc">
                  <ol>
                    <li><a href="b.xhtml">Bravo Chapter</a></li>
                    <li><a href="a.xhtml#s1">Alpha Chapter</a></li>
                  </ol>
                </nav>
              </body>
            </html>
            """
        let alpha = "<html><body><p>ALPHA_CONTENT</p></body></html>"
        let bravo = "<html><body><p>BRAVO_CONTENT</p></body></html>"

        let url = try makeArchive(
            "test.epub",
            entries: [
                ("META-INF/container.xml", container),
                ("OEBPS/content.opf", opf),
                ("OEBPS/nav.xhtml", nav),
                ("OEBPS/a.xhtml", alpha),
                ("OEBPS/b.xhtml", bravo),
            ]
        )

        let content = try ContentLoader.load(format: .epub, fileURL: url)
        guard case .epub(let text, let entries) = content else {
            return XCTFail("expected .epub content, got \(content)")
        }

        // Spine declares b before a even though a sorts first by path.
        let haystack = text.string as NSString
        let bravoRange = haystack.range(of: "BRAVO_CONTENT")
        let alphaRange = haystack.range(of: "ALPHA_CONTENT")
        XCTAssertNotEqual(bravoRange.location, NSNotFound)
        XCTAssertNotEqual(alphaRange.location, NSNotFound)
        XCTAssertLessThan(bravoRange.location, alphaRange.location)

        XCTAssertEqual(entries.map(\.title), ["Bravo Chapter", "Alpha Chapter"])
        XCTAssertEqual(entries[0].textOffset, 0)
        if let alphaOffset = entries[1].textOffset {
            // HTML parsing may add a few whitespace chars; the locator
            // should land within the chapter, not at an exact index.
            XCTAssertLessThanOrEqual(
                abs(alphaRange.location - alphaOffset),
                4
            )
        } else {
            XCTFail("Alpha Chapter entry has no text offset")
        }
    }

    func testEPUBFallsBackWithoutContainer() throws {
        let a = "<html><body><p>ONLY_CHAPTER</p></body></html>"
        let url = try makeArchive(
            "bare.epub",
            entries: [("chapter1.xhtml", a)]
        )
        let content = try ContentLoader.load(format: .epub, fileURL: url)
        guard case .epub(let text, let entries) = content else {
            return XCTFail("expected .epub content, got \(content)")
        }
        XCTAssertTrue(text.string.contains("ONLY_CHAPTER"))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "chapter1")
    }

    func testDOCXExtraction() throws {
        let document = """
            <?xml version="1.0"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:body>
                <w:p><w:r><w:t>Docx says hi</w:t></w:r></w:p>
                <w:p><w:r><w:t>Second paragraph</w:t></w:r></w:p>
              </w:body>
            </w:document>
            """
        let url = try makeArchive(
            "test.docx",
            entries: [("word/document.xml", document)]
        )
        let content = try ContentLoader.load(format: .docx, fileURL: url)
        guard case .attributedText(let text) = content else {
            return XCTFail("expected .attributedText, got \(content)")
        }
        XCTAssertTrue(text.string.contains("Docx says hi"))
        XCTAssertTrue(text.string.contains("Second paragraph"))
    }

    func testFB2Extraction() throws {
        let fb2 = """
            <?xml version="1.0"?>
            <FictionBook>
              <body>
                <section>
                  <title><p>Chapter One</p></title>
                  <p>Hello fiction.</p>
                </section>
              </body>
            </FictionBook>
            """
        let url = try makeFile("book.fb2", contents: fb2)
        let content = try ContentLoader.load(format: .fb2, fileURL: url)
        guard case .attributedText(let text) = content else {
            return XCTFail("expected .attributedText, got \(content)")
        }
        XCTAssertTrue(text.string.contains("Chapter One"))
        XCTAssertTrue(text.string.contains("Hello fiction."))
    }

    func testMOBIUncompressedExtraction() throws {
        // Minimal PalmDB: record table at 78 (8 bytes per entry),
        // PalmDOC header at 256, one uncompressed text record at 512.
        var data = Data(count: 1024)
        func put16(_ value: UInt16, at offset: Int) {
            data[offset] = UInt8(value >> 8)
            data[offset + 1] = UInt8(value & 0xFF)
        }
        func put32(_ value: UInt32, at offset: Int) {
            data[offset] = UInt8((value >> 24) & 0xFF)
            data[offset + 1] = UInt8((value >> 16) & 0xFF)
            data[offset + 2] = UInt8((value >> 8) & 0xFF)
            data[offset + 3] = UInt8(value & 0xFF)
        }
        put16(3, at: 76) // record count
        put32(256, at: 78) // record 0 offset (PalmDOC header)
        put32(512, at: 86) // record 1 offset (text)
        put32(768, at: 94) // record 2 offset (unused trailer)
        put16(1, at: 256) // compression = none
        let text = "Hello MOBI world"
        put32(UInt32(text.utf8.count), at: 260) // text length
        put16(1, at: 264) // text record count
        data.replaceSubrange(
            512..<(512 + text.utf8.count),
            with: text.utf8
        )
        let url = tempDir.appendingPathComponent("book.mobi")
        try data.write(to: url)

        let content = try ContentLoader.load(format: .mobi, fileURL: url)
        guard case .attributedText(let attributed) = content else {
            return XCTFail("expected .attributedText, got \(content)")
        }
        XCTAssertTrue(attributed.string.contains("Hello MOBI world"))
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(
            try ContentLoader.load(
                format: .epub,
                fileURL: tempDir.appendingPathComponent("nope.epub")
            )
        ) { error in
            guard case .missingFile = error as? ContentLoadingError else {
                return XCTFail("expected .missingFile, got \(error)")
            }
        }
    }
}

final class ResearchRetrievalTests: XCTestCase {
    private func filler(_ count: Int) -> String {
        String(repeating: "Unrelated filler describes weather patterns over coastal towns. ", count: count)
    }

    func testEveryRelevantChunkOnAPDFPageCanBeRetrieved() async throws {
        let first = "Hippocampal replay strengthens memory traces overnight. " + filler(20)
        let second = filler(20) + "Hippocampal replay also predicts next-day recall. "
        let url = try makePDF(pages: [first + second])
        let chunks = ResearchIndex.extract(format: .pdf, url: url, text: nil)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.locator == "pdf:0" })

        let citations = await ResearchIndex(vectorDirectory: nil).search(
            bookID: UUID(), contentHash: "pdf", format: .pdf, url: url,
            extractedText: nil, question: "hippocampal replay", selected: nil,
            semanticWait: .zero
        )
        XCTAssertTrue(citations.contains { $0.quote.contains("strengthens memory") })
        XCTAssertTrue(citations.contains { $0.quote.contains("next-day recall") })
    }

    func testStemmingMatchesWordForms() async {
        XCTAssertEqual(ResearchIndex.stem("consolidating"), ResearchIndex.stem("consolidation"))
        XCTAssertEqual(ResearchIndex.stem("consolidated"), ResearchIndex.stem("consolidate"))
        XCTAssertEqual(ResearchIndex.stem("memories"), ResearchIndex.stem("memory"))
        XCTAssertEqual(ResearchIndex.stem("processes"), ResearchIndex.stem("process"))
        XCTAssertEqual(ResearchIndex.stem("learning"), ResearchIndex.stem("learned"))

        let citations = await ResearchIndex(vectorDirectory: nil).search(
            bookID: UUID(), contentHash: "stem", format: .txt, url: nil,
            extractedText: filler(40) + "Consolidation of memories happens during rest. " + filler(40),
            question: "When are memory traces consolidated?", selected: nil,
            semanticWait: .zero
        )
        XCTAssertEqual(citations.first.map { $0.quote.contains("Consolidation of memories") }, true)
    }

    func testRareTermsOutrankCommonOnes() async {
        let text = String(repeating: "The model explains behavior in many settings. ", count: 60)
            + filler(30) + "Only here does the model mention dopamine. " + filler(30)
        let citations = await ResearchIndex(vectorDirectory: nil).search(
            bookID: UUID(), contentHash: "idf", format: .txt, url: nil,
            extractedText: text, question: "model dopamine", selected: nil,
            semanticWait: .zero
        )
        XCTAssertTrue(citations.first?.quote.contains("dopamine") ?? false)
    }

    func testSemanticSearchFindsParaphrasesWithoutSharedWords() async throws {
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        try XCTSkipIf(embedding == nil, "English sentence embedding unavailable")
        let text = [
            "The Treaty of Westphalia ended decades of war and redrew the political map of Europe.",
            "Photosynthesis turns light into chemical energy that plants store as glucose.",
            "During slow-wave sleep the hippocampus replays the day's experiences, stabilizing them in cortex.",
            "Participants completed a questionnaire about their commute and household income.",
        ].map { $0 + " " + String(repeating: "\n", count: 1) }.joined(separator: filler(18))
        let citations = await ResearchIndex(vectorDirectory: nil).search(
            bookID: UUID(), contentHash: "semantic", format: .txt, url: nil,
            extractedText: text, question: "How are memories strengthened at night?",
            selected: nil, semanticWait: .seconds(30)
        )
        XCTAssertTrue(citations.first?.quote.contains("hippocampus") ?? false, "\(citations.map(\.quote))")
    }

    func testChunksBreakAtSentencesAndOverlap() {
        let sentence = "This sentence is exactly about sixty characters long, roughly. "
        let text = String(repeating: sentence, count: 60)
        let chunks = ResearchIndex.chunks(text)
        XCTAssertGreaterThan(chunks.count, 2)
        for (range, fragment) in chunks.dropLast() {
            XCTAssertTrue(fragment.hasSuffix("roughly."), fragment)
            XCTAssertLessThanOrEqual(range.length, ResearchIndex.chunkLength)
        }
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            XCTAssertLessThan(next.0.location, NSMaxRange(previous.0), "chunks should overlap")
            XCTAssertGreaterThan(next.0.location, previous.0.location)
        }
        XCTAssertEqual(NSMaxRange(chunks.last!.0), (text as NSString).length)
    }

    func testCitationLabelsUseSectionTitles() async throws {
        let text = "Introduction text. " + filler(30) + "Methods: we sampled zebrafish larvae. " + filler(10)
        let methodsOffset = (text as NSString).range(of: "Methods:").location
        let contents = [
            BookContentEntry(id: "1", title: "Introduction", locator: "text:0:0", level: 0),
            BookContentEntry(id: "2", title: "Methods", locator: "text:\(methodsOffset - 5):0", level: 0),
        ]
        let citations = await ResearchIndex(vectorDirectory: nil).search(
            bookID: UUID(), contentHash: "labels", format: .txt, url: nil,
            extractedText: text, question: "zebrafish", selected: nil,
            contents: contents, semanticWait: .zero
        )
        let hit = try XCTUnwrap(citations.first { $0.quote.contains("zebrafish") })
        XCTAssertTrue(["Methods", "Introduction"].contains(hit.label))

        let pdf = try makePDF(pages: ["Cover", "Zebrafish larvae were sampled."])
        let pdfCitations = await ResearchIndex(vectorDirectory: nil).search(
            bookID: UUID(), contentHash: "pdf-labels", format: .pdf, url: pdf,
            extractedText: nil, question: "zebrafish", selected: nil,
            contents: [BookContentEntry(id: "m", title: "Methods", locator: "pdf:1", level: 0)],
            semanticWait: .zero
        )
        XCTAssertEqual(pdfCitations.first?.label, "Page 2 · Methods")
    }

    func testVectorStoreRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("v.vectors")
        let vectors = EmbeddingMatrix(rows: 2, dimension: 3, values: [0.1, 0.2, 0.3, -1, 0, 1])
        ResearchVectorStore.write(vectors, to: url)
        XCTAssertEqual(ResearchVectorStore.read(url), vectors)
        try Data([1, 2, 3]).write(to: url)
        XCTAssertNil(ResearchVectorStore.read(url))
    }

    private func makePDF(pages: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: page, attributes: [.font: NSFont.systemFont(ofSize: 7)]
            )
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: box.insetBy(dx: 36, dy: 36), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}

private final class CrossrefFixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CitationExportTests: XCTestCase {
    private let article = CitationMetadata(
        doi: "10.1016/j.neuron.2013.12.025", type: "journal-article",
        title: "Sleep and the Price of Plasticity: From Synaptic and Cellular Homeostasis to Memory Consolidation & Integration",
        authors: [.init(given: "Giulio", family: "Tononi"), .init(given: "Chiara", family: "Cirelli")],
        year: 2014, container: "Neuron", publisher: "Elsevier BV",
        volume: "81", issue: "1", pages: "12-34"
    )

    private let crossrefJSON = """
        {"status":"ok","message":{"DOI":"10.1016/J.NEURON.2013.12.025","type":"journal-article",
        "title":["Sleep and the Price of Plasticity:  From Synaptic\\n and Cellular Homeostasis"],
        "author":[{"given":"Giulio","family":"Tononi"},{"given":"Chiara","family":"Cirelli"},{"name":"Sleep Consortium"}],
        "issued":{"date-parts":[[2014,1]]},"container-title":["Neuron"],"publisher":"Elsevier BV",
        "volume":"81","issue":"1","page":"12-34"}}
        """

    func testDOIDetectionTrimsPunctuationAndKeepsBalancedParentheses() {
        let text = """
            Available at https://doi.org/10.1038/nature12373. See also (doi:10.1016/S0140-6736(20)30183-5),
            and again 10.1038/NATURE12373;
            """
        XCTAssertEqual(DOIDetector.all(in: text), ["10.1038/nature12373", "10.1016/s0140-6736(20)30183-5"])
        XCTAssertEqual(DOIDetector.all(in: "No identifiers here, 10.12/short"), [])
    }

    func testDetectedDOIMustMatchTheDocumentTitle() {
        let firstPage = "Neuron Review. Sleep and the Price of Plasticity: From Synaptic and Cellular Homeostasis"
        XCTAssertTrue(DOIDetector.titleAppears("Sleep and the price of plasticity", in: firstPage))
        XCTAssertFalse(DOIDetector.titleAppears("Hippocampal replay predicts recall", in: firstPage))
    }

    func testCrossrefParsing() async throws {
        let parsed = try XCTUnwrap(CrossrefMetadataClient.parse(Data(crossrefJSON.utf8)))
        XCTAssertEqual(parsed.doi, "10.1016/j.neuron.2013.12.025")
        XCTAssertEqual(parsed.title, "Sleep and the Price of Plasticity: From Synaptic and Cellular Homeostasis")
        XCTAssertEqual(parsed.authors.map(\.family), ["Tononi", "Cirelli", "Sleep Consortium"])
        XCTAssertEqual(parsed.year, 2014)
        XCTAssertEqual(parsed.container, "Neuron")
        XCTAssertEqual(parsed.pages, "12-34")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrossrefFixtureURLProtocol.self]
        let client = CrossrefMetadataClient(session: URLSession(configuration: configuration))
        CrossrefFixtureURLProtocol.body = Data(crossrefJSON.utf8)
        CrossrefFixtureURLProtocol.status = 200
        let fetched = try await client.metadata(doi: "https://doi.org/10.1016/j.neuron.2013.12.025")
        XCTAssertEqual(fetched, parsed)
        CrossrefFixtureURLProtocol.status = 404
        let missing = try await client.metadata(doi: "10.1016/j.neuron.2013.12.025")
        XCTAssertNil(missing)
        CrossrefFixtureURLProtocol.status = 503
        do {
            _ = try await client.metadata(doi: "10.1016/j.neuron.2013.12.025")
            XCTFail("Expected an error")
        } catch {}
    }

    func testNonCrossrefDOIsParseFromCSLJSON() throws {
        let csl = """
            {"type":"article","title":"Attention Is All You Need","publisher":"arXiv",
            "DOI":"10.48550/ARXIV.1706.03762","issued":{"date-parts":[[2017]]},
            "author":[{"family":"Vaswani","given":"Ashish"},{"literal":"Google Brain"}]}
            """
        let paper = try XCTUnwrap(CrossrefMetadataClient.parseCSL(Data(csl.utf8)))
        XCTAssertEqual(paper.type, "posted-content")
        XCTAssertEqual(paper.year, 2017)
        XCTAssertEqual(paper.authors.map(\.family), ["Vaswani", "Google Brain"])
        XCTAssertEqual(
            CitationFormatter.apa(paper),
            "Vaswani, A., & Google Brain. (2017). Attention Is All You Need. arXiv. https://doi.org/10.48550/arxiv.1706.03762"
        )
        XCTAssertTrue(CitationFormatter.bibTeX(paper).contains("  publisher = {arXiv},"))
    }

    func testChapterUsesVolumeTitleRatherThanSeries() throws {
        let json = """
            {"message":{"DOI":"10.1007/978-3-319-24574-4_28","type":"book-chapter","title":["U-Net"],
            "container-title":["Lecture Notes in Computer Science","MICCAI 2015"]}}
            """
        XCTAssertEqual(CrossrefMetadataClient.parse(Data(json.utf8))?.container, "MICCAI 2015")
    }

    func testBibTeXForJournalArticle() {
        XCTAssertEqual(CitationFormatter.bibTeX(article), """
            @article{tononi2014sleep,
              author = {Tononi, Giulio and Cirelli, Chiara},
              title = {{Sleep and the Price of Plasticity: From Synaptic and Cellular Homeostasis to Memory Consolidation \\& Integration}},
              journal = {Neuron},
              year = {2014},
              volume = {81},
              number = {1},
              pages = {12--34},
              publisher = {Elsevier BV},
              doi = {10.1016/j.neuron.2013.12.025}
            }
            """)
    }

    func testFallbackCitationFromLibraryRecord() {
        let book = CitationMetadata.fallback(title: "The Shape of Attention", author: "Eva Arden and Jean-Paul Sartre", format: .epub)
        XCTAssertEqual(book.type, "book")
        XCTAssertEqual(book.authors, [.init(given: "Eva", family: "Arden"), .init(given: "Jean-Paul", family: "Sartre")])
        XCTAssertTrue(CitationFormatter.bibTeX(book).hasPrefix("@book{ardenshape,"))
        XCTAssertEqual(CitationFormatter.apa(book), "Arden, E., & Sartre, J.-P. (n.d.). The Shape of Attention.")

        let unknown = CitationMetadata.fallback(title: "Notes", author: "Unknown Author", format: .pdf)
        XCTAssertTrue(unknown.authors.isEmpty)
        XCTAssertTrue(CitationFormatter.bibTeX(unknown).hasPrefix("@misc{notes,"))
    }

    func testAPAReferenceAndInTextCitations() {
        XCTAssertEqual(
            CitationFormatter.apa(article, markdown: true),
            "Tononi, G., & Cirelli, C. (2014). Sleep and the Price of Plasticity: From Synaptic and Cellular Homeostasis to Memory Consolidation & Integration. *Neuron*, *81*(1), 12–34. https://doi.org/10.1016/j.neuron.2013.12.025"
        )
        var single = article
        single.authors = [article.authors[0]]
        XCTAssertEqual(CitationFormatter.inText(single, page: 12), "(Tononi, 2014, p. 12)")
        XCTAssertEqual(CitationFormatter.inText(article), "(Tononi & Cirelli, 2014)")
        var many = article
        many.authors.append(.init(given: "A", family: "Third"))
        many.year = nil
        XCTAssertEqual(CitationFormatter.inText(many), "(Tononi et al., n.d.)")
        XCTAssertEqual(
            CitationFormatter.quote("  Sleep is the price we pay. ", citation: single, page: 3),
            "“Sleep is the price we pay.” (Tononi, 2014, p. 3)"
        )
    }

    func testMarkdownNotesAreOrderedGroupedAndCitable() {
        let base = Date(timeIntervalSince1970: 0)
        let highlights = [
            ExportedHighlight(quote: "Later page", note: "", color: .rose, locator: "pdf:9", chapter: "Discussion", createdAt: base),
            ExportedHighlight(quote: "Line one\nLine two", note: "  My note.  ", color: .amber, locator: "pdf:1", chapter: "Introduction", createdAt: base.addingTimeInterval(10)),
            ExportedHighlight(quote: "Same chapter", note: "", color: .sage, locator: "pdf:2", chapter: "Introduction", createdAt: base),
        ]
        var titled = article
        titled.title = "Sleep \"and\" plasticity"
        let markdown = NotesMarkdown.document(citation: titled, highlights: highlights, exportedAt: base)
        XCTAssertTrue(markdown.hasPrefix("---\ntitle: \"Sleep \\\"and\\\" plasticity\"\nauthors:\n  - \"Giulio Tononi\"\n"))
        XCTAssertTrue(markdown.contains("citekey: tononi2014sleep\nhighlights: 3\nexported: 1970-01-01\n"))
        XCTAssertTrue(markdown.contains("""
            ## Introduction

            > Line one
            > Line two
            >
            > — p. 2 · Amber [@tononi2014sleep, p. 2]

            My note.

            > Same chapter
            >
            > — p. 3 · Sage [@tononi2014sleep, p. 3]

            ## Discussion

            > Later page
            """))
        XCTAssertEqual(markdown.components(separatedBy: "## Introduction").count, 2)

        let text = [ExportedHighlight(quote: "Q", note: "", color: .amber, locator: "text:40:1", chapter: "Start reading", createdAt: base)]
        let textMarkdown = NotesMarkdown.document(citation: titled, highlights: text, exportedAt: base)
        XCTAssertFalse(textMarkdown.contains("## "))
        XCTAssertTrue(textMarkdown.contains("> — Amber [@tononi2014sleep]"))
    }

    func testExportFileNames() {
        XCTAssertEqual(NotesMarkdown.fileName(for: "Behave: The Biology / of Humans?"), "Behave The Biology of Humans.md")
        XCTAssertEqual(NotesMarkdown.fileName(for: " ... "), "Notes.md")
    }

    func testBookCitationPersists() throws {
        let book = BookRecord(title: "Draft", author: "Researcher", format: .pdf)
        XCTAssertNil(book.citation)
        book.citation = article
        XCTAssertEqual(book.citation, article)
        book.citation = nil
        XCTAssertTrue(book.citationData.isEmpty)
    }
}

final class NotebookTests: XCTestCase {
    func testDriftedHighlightsReanchorToNearestQuote() {
        let text = "Alpha beta. Gamma delta. Alpha beta again." as NSString
        XCTAssertNil(AnnotationAnchoring.repairedLocator("text:0:10", quote: "Alpha beta", in: text))
        XCTAssertEqual(AnnotationAnchoring.repairedLocator("text:2:10", quote: "Alpha beta", in: text), "text:0:10")
        XCTAssertEqual(AnnotationAnchoring.repairedLocator("text:30:10", quote: "Alpha beta", in: text), "text:25:10")
        XCTAssertNil(AnnotationAnchoring.repairedLocator("text:0:5", quote: "Missing", in: text))
        XCTAssertNil(AnnotationAnchoring.repairedLocator("text:4:0", quote: "", in: text))
        XCTAssertEqual(AnnotationAnchoring.repairedLocator("text:900:10", quote: "Gamma delta", in: text), "text:12:11")
        XCTAssertEqual(AnnotationAnchoring.repairedLocator("text:3:12", quote: "Gamma delta:", in: text), "text:12:11")
    }

    func testSampleHighlightsCoverTheirQuotes() {
        let sample = ContentLoader.sampleChapter as NSString
        for quote in [
            "Some lines need to remain open for a while. They gather meaning from what follows",
            "The strongest notes are not summaries of what the author has said. They are records of contact",
        ] {
            XCTAssertNotEqual(sample.range(of: quote).location, NSNotFound, quote)
        }
    }

    func testNotebookUsesReadingOrder() {
        XCTAssertTrue(AnnotationLocation.position("pdf:2") < AnnotationLocation.position("pdf:10"))
        XCTAssertTrue(AnnotationLocation.position("text:40:3") < AnnotationLocation.position("text:400:0"))
        XCTAssertEqual(AnnotationLocation.page("pdf:0"), 1)
        XCTAssertNil(AnnotationLocation.page("text:0:1"))
    }

    func testPageNotesExportWithoutQuotes() {
        let citation = CitationMetadata(type: "document", title: "Paper", authors: [.init(given: "Ada", family: "Lovelace")], year: 1843)
        let notes = [
            ExportedHighlight(quote: "", note: "Compare with chapter 2.", color: .amber, locator: "pdf:4", chapter: "", createdAt: .now),
            ExportedHighlight(quote: "", note: "   ", color: .amber, locator: "pdf:5", chapter: "", createdAt: .now),
        ]
        let markdown = NotesMarkdown.document(citation: citation, highlights: notes)
        XCTAssertTrue(markdown.contains("**Note** · p. 5 [@lovelace1843paper, p. 5]\n\nCompare with chapter 2."))
        XCTAssertFalse(markdown.contains("p. 6"))
        XCTAssertTrue(markdown.contains("highlights: 0"))
    }

    @MainActor
    func testNoteShortcutWithoutSelectionStartsAPageNote() throws {
        let container = try ModelContainer(
            for: BookRecord.self, AnnotationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let book = BookRecord(title: "Essay", author: "A", format: .txt, lastLocator: "text:120:0")
        context.insert(book)
        let store = ReaderStore()
        store.selectedBook = book
        store.companionPane = .ai
        store.inspectorVisible = false
        store.inspectorTab = 1

        store.addNote(context: context)
        let note = try XCTUnwrap(try context.fetch(FetchDescriptor<AnnotationRecord>()).first)
        XCTAssertEqual(note.quote, "")
        XCTAssertEqual(note.locator, "text:120:0")
        XCTAssertEqual(store.editingAnnotationID, note.id)
        XCTAssertEqual(store.companionPane, .notebook)
        XCTAssertTrue(store.inspectorVisible)
        XCTAssertEqual(store.inspectorTab, 0, "the empty entry must not be hidden by the Notes filter")

        store.finishEditingNote(note, context: context)
        XCTAssertNil(store.editingAnnotationID)
        XCTAssertTrue(try context.fetch(FetchDescriptor<AnnotationRecord>()).isEmpty, "empty page notes are discarded")
    }

    @MainActor
    func testNoteOnSelectionOpensEditorForNewHighlight() throws {
        let container = try ModelContainer(
            for: BookRecord.self, AnnotationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let book = BookRecord(title: "Essay", author: "A", format: .txt)
        context.insert(book)
        let store = ReaderStore()
        store.selectedBook = book
        store.selectedTextRange = NSRange(location: 10, length: 5)
        store.selectedTextQuote = "hello"

        store.addNote(context: context)
        let highlight = try XCTUnwrap(try context.fetch(FetchDescriptor<AnnotationRecord>()).first)
        XCTAssertEqual(highlight.quote, "hello")
        XCTAssertEqual(store.editingAnnotationID, highlight.id)

        highlight.note = "  keep me  "
        store.finishEditingNote(highlight, context: context)
        XCTAssertEqual(highlight.note, "keep me")
        XCTAssertEqual(try context.fetch(FetchDescriptor<AnnotationRecord>()).count, 1)

        store.finishEditingNote(highlight, context: context)
        highlight.note = ""
        store.finishEditingNote(highlight, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AnnotationRecord>()).count, 1, "highlights stay without a note")
    }
}
