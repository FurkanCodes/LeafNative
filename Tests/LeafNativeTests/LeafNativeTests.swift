import XCTest
import ZIPFoundation
import SwiftData
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

final class ResearchCompanionTests: XCTestCase {
    func testCurrentPassageWinsOverWholeDocumentMatches() async {
        let index = ResearchIndex()
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
        let index = ResearchIndex()
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
