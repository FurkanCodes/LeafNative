import XCTest
import ZIPFoundation
@testable import LeafNative

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
