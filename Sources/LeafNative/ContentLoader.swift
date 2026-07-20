import AppKit
import Foundation
import PDFKit
import ZIPFoundation

enum ContentLoadingError: LocalizedError {
    case missingFile
    case unreadable(String)
    case unsupportedCompression

    var errorDescription: String? {
        switch self {
        case .missingFile:
            "The book file is no longer available."
        case .unreadable(let detail):
            "Leaf could not read this publication. \(detail)"
        case .unsupportedCompression:
            "This Kindle file uses HUFF/CDIC compression, which this build does not decode."
        }
    }
}

@MainActor
enum ContentLoader {
    static func load(_ book: BookRecord) throws -> LoadedBookContent {
        if book.format == .sample {
            return .attributedText(NSAttributedString(string: sampleChapter))
        }

        guard let url = book.fileURL,
              FileManager.default.fileExists(atPath: url.path)
        else {
            throw ContentLoadingError.missingFile
        }

        switch book.format {
        case .pdf:
            return .pdf(url)
        case .txt:
            return .attributedText(
                NSAttributedString(string: try readString(url))
            )
        case .markdown:
            let source = try readString(url)
            let attributed = try AttributedString(
                markdown: source,
                options: .init(interpretedSyntax: .full)
            )
            return .attributedText(NSAttributedString(attributed))
        case .html:
            return .attributedText(
                try htmlAttributedString(from: Data(contentsOf: url))
            )
        case .rtf, .rtfd, .doc:
            return .attributedText(try attributedDocument(at: url))
        case .docx:
            return .attributedText(
                NSAttributedString(string: try readDOCX(url))
            )
        case .epub:
            return .attributedText(try readEPUB(url))
        case .fb2:
            return .attributedText(
                NSAttributedString(string: try readFB2(url))
            )
        case .cbz:
            return .comic(try readComicArchive(url))
        case .mobi, .azw, .azw3:
            return .attributedText(try readMOBI(url))
        case .cbr, .unknown:
            return .quickLook(url)
        case .sample:
            return .attributedText(NSAttributedString(string: sampleChapter))
        }
    }

    static func tableOfContents(for book: BookRecord) throws -> [BookContentEntry] {
        if book.format == .sample {
            return sampleContents()
        }

        guard let url = book.fileURL,
              FileManager.default.fileExists(atPath: url.path)
        else {
            throw ContentLoadingError.missingFile
        }

        switch book.format {
        case .pdf:
            return pdfContents(at: url)
        default:
            return []
        }
    }

    private static func pdfContents(at url: URL) -> [BookContentEntry] {
        guard let document = PDFDocument(url: url),
              let root = document.outlineRoot
        else { return [] }

        var entries: [BookContentEntry] = []
        var ordinal = 0

        func appendChildren(of outline: PDFOutline, level: Int) {
            guard entries.count < 500 else { return }

            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }

                let destination = child.destination
                    ?? (child.action as? PDFActionGoTo)?.destination
                if let page = destination?.page {
                    let pageIndex = document.index(for: page)
                    let title = child.label?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if pageIndex != NSNotFound, let title, !title.isEmpty {
                        entries.append(
                            BookContentEntry(
                                id: "pdf-outline:\(ordinal):\(pageIndex)",
                                title: title,
                                locator: "pdf:\(pageIndex)",
                                level: level
                            )
                        )
                        ordinal += 1
                    }
                }

                appendChildren(of: child, level: level + 1)
                if entries.count >= 500 { return }
            }
        }

        appendChildren(of: root, level: 0)
        return entries
    }

    private static func sampleContents() -> [BookContentEntry] {
        let source = sampleChapter as NSString
        let headings: [(String, Int)] = [
            ("A Practice of Noticing", 0),
            ("THE INTERVAL BEFORE JUDGMENT", 1),
            ("MAKE A PLACE FOR RETURN", 1),
        ]

        return headings.enumerated().compactMap { index, heading in
            let range = source.range(of: heading.0)
            guard range.location != NSNotFound else { return nil }
            return BookContentEntry(
                id: "sample:\(index)",
                title: heading.0.capitalized,
                locator: "text:\(range.location):\(range.length)",
                level: heading.1
            )
        }
    }

    private static func readString(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        for encoding in [
            String.Encoding.utf8,
            .utf16,
            .windowsCP1252,
            .isoLatin1,
        ] {
            if let value = String(data: data, encoding: encoding) {
                return value
            }
        }
        throw ContentLoadingError.unreadable("The text encoding is unknown.")
    }

    private static func attributedDocument(at url: URL) throws -> NSAttributedString {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: documentType(for: url),
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        return try NSAttributedString(
            url: url,
            options: options,
            documentAttributes: nil
        )
    }

    private static func documentType(for url: URL) -> NSAttributedString.DocumentType {
        switch ReaderFormat(url: url) {
        case .rtf: .rtf
        case .rtfd: .rtfd
        case .doc: .docFormat
        default: .plain
        }
    }

    private static func htmlAttributedString(from data: Data) throws -> NSAttributedString {
        try NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        )
    }

    private static func archiveData(
        named name: String,
        in archive: Archive
    ) throws -> Data {
        guard let entry = archive[name] else {
            throw ContentLoadingError.unreadable("The archive is missing \(name).")
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return data
    }

    private static func readDOCX(_ url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        let xml = try archiveData(named: "word/document.xml", in: archive)
        return XMLTextExtractor.extract(
            data: xml,
            paragraphElements: ["p"],
            textElements: ["t"]
        )
    }

    private static func readEPUB(_ url: URL) throws -> NSAttributedString {
        let archive = try Archive(url: url, accessMode: .read)
        let htmlEntries = archive
            .filter {
                !$0.path.hasPrefix("__MACOSX") &&
                    ["html", "htm", "xhtml"].contains(
                        URL(fileURLWithPath: $0.path).pathExtension.lowercased()
                    )
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .prefix(80)

        let result = NSMutableAttributedString()
        for entry in htmlEntries {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            if let chapter = try? htmlAttributedString(from: data),
               chapter.length > 0 {
                if result.length > 0 {
                    result.append(NSAttributedString(string: "\n\n"))
                }
                result.append(chapter)
            }
        }

        guard result.length > 0 else {
            throw ContentLoadingError.unreadable(
                "No readable XHTML chapters were found."
            )
        }
        return result
    }

    private static func readFB2(_ url: URL) throws -> String {
        XMLTextExtractor.extract(
            data: try Data(contentsOf: url),
            paragraphElements: ["p", "subtitle", "title"],
            textElements: []
        )
    }

    private static func readComicArchive(_ url: URL) throws -> [Data] {
        let archive = try Archive(url: url, accessMode: .read)
        let imageEntries = archive
            .filter {
                ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(
                    URL(fileURLWithPath: $0.path).pathExtension.lowercased()
                )
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .prefix(150)

        var images: [Data] = []
        for entry in imageEntries {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            images.append(data)
        }
        guard !images.isEmpty else {
            throw ContentLoadingError.unreadable(
                "No supported images were found in the comic archive."
            )
        }
        return images
    }

    private static func readMOBI(_ url: URL) throws -> NSAttributedString {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let text = try MOBITextExtractor.extract(data)
        if let html = text.data(using: .utf8),
           let result = try? htmlAttributedString(from: html),
           result.length > 0 {
            return result
        }
        return NSAttributedString(string: text)
    }

    static let sampleChapter = """
    CHAPTER FOUR

    A Practice of Noticing

    Attention is less like a spotlight and more like a room we learn to inhabit.

    We imagine attention as a force we direct: a beam aimed at one task, one page, one person. This is useful, but incomplete. A beam illuminates only what it has already found. The more durable kind of attention begins before selection, in the quiet willingness to notice what is present.

    To read carefully is to resist the small urge to turn every sentence into a conclusion. Some lines need to remain open for a while. They gather meaning from what follows, and sometimes from what the reader brings back on a second pass.

    THE INTERVAL BEFORE JUDGMENT

    There is an interval—brief but trainable—between seeing a thing and deciding what it means. Most of us rush across it. We name, sort, and move on. Study begins when we stay inside that interval long enough for the obvious reading to loosen its grip.

    “The quality of an observation depends on the patience of the observer.”

    This patience is active. It asks us to hold several possibilities at once, to mark a phrase without yet knowing why it matters, and to allow a question to survive beyond the page on which it first appeared.

    A notebook helps because it makes uncertainty visible. The strongest notes are not summaries of what the author has said. They are records of contact: a disagreement, a connection, a phrase that changes the temperature of an idea.

    MAKE A PLACE FOR RETURN

    Highlighting becomes useful when it is selective enough to create a path back through the book. A page flooded with color remembers nothing. A few deliberate marks, each attached to a reason, become a second table of contents—one made by the reader.

    The aim is not to finish with a perfect record. It is to leave behind useful handles: passages you can lift, questions you can reopen, and connections that make the next reading richer than the first.
    """
}

private final class XMLTextExtractor: NSObject, XMLParserDelegate {
    private let paragraphElements: Set<String>
    private let textElements: Set<String>
    private var output: [String] = []
    private var current = ""
    private var paragraphDepth = 0
    private var captureAllText: Bool { textElements.isEmpty }

    init(paragraphElements: [String], textElements: [String]) {
        self.paragraphElements = Set(paragraphElements)
        self.textElements = Set(textElements)
    }

    static func extract(
        data: Data,
        paragraphElements: [String],
        textElements: [String]
    ) -> String {
        let delegate = XMLTextExtractor(
            paragraphElements: paragraphElements,
            textElements: textElements
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.output.joined(separator: "\n\n")
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if paragraphElements.contains(name) {
            paragraphDepth += 1
            if paragraphDepth == 1 {
                current = ""
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard paragraphDepth > 0 || captureAllText else { return }
        current += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        guard paragraphElements.contains(name) else { return }
        paragraphDepth -= 1
        if paragraphDepth == 0 {
            let text = current
                .replacingOccurrences(
                    of: "\\s+",
                    with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                output.append(text)
            }
        }
    }
}

private enum MOBITextExtractor {
    static func extract(_ data: Data) throws -> String {
        guard data.count > 90 else {
            throw ContentLoadingError.unreadable("The MOBI header is incomplete.")
        }

        let recordCount = Int(readUInt16(data, at: 76))
        guard recordCount > 1 else {
            throw ContentLoadingError.unreadable("No text records were found.")
        }

        var offsets: [Int] = []
        for index in 0..<recordCount {
            let position = 78 + index * 8
            guard position + 4 <= data.count else { break }
            offsets.append(Int(readUInt32(data, at: position)))
        }
        offsets.append(data.count)
        guard offsets.count >= 3 else {
            throw ContentLoadingError.unreadable("The record table is invalid.")
        }

        let headerOffset = offsets[0]
        guard headerOffset + 16 <= data.count else {
            throw ContentLoadingError.unreadable("The PalmDOC header is missing.")
        }

        let compression = Int(readUInt16(data, at: headerOffset))
        let textLength = Int(readUInt32(data, at: headerOffset + 4))
        let textRecordCount = Int(readUInt16(data, at: headerOffset + 8))

        guard compression == 1 || compression == 2 else {
            throw ContentLoadingError.unsupportedCompression
        }

        var output = Data()
        for index in 1...min(textRecordCount, offsets.count - 2) {
            let start = offsets[index]
            let end = offsets[index + 1]
            guard start >= 0, end <= data.count, start < end else { continue }
            let record = data.subdata(in: start..<end)
            output.append(
                compression == 2 ? decompressPalmDOC(record) : record
            )
            if output.count >= textLength { break }
        }

        if output.count > textLength {
            output = output.prefix(textLength)
        }
        return String(data: output, encoding: .utf8)
            ?? String(data: output, encoding: .windowsCP1252)
            ?? String(decoding: output, as: UTF8.self)
    }

    private static func decompressPalmDOC(_ input: Data) -> Data {
        let bytes = [UInt8](input)
        var output: [UInt8] = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            index += 1

            switch byte {
            case 0:
                output.append(0)
            case 1...8:
                let count = min(Int(byte), bytes.count - index)
                output.append(contentsOf: bytes[index..<(index + count)])
                index += count
            case 9...127:
                output.append(byte)
            case 128...191:
                guard index < bytes.count else { break }
                let pair = (UInt16(byte) << 8) | UInt16(bytes[index])
                index += 1
                let distance = Int((pair >> 3) & 0x07FF)
                let length = Int(pair & 0x0007) + 3
                guard distance > 0, distance <= output.count else { continue }
                for _ in 0..<length {
                    output.append(output[output.count - distance])
                }
            default:
                output.append(0x20)
                output.append(byte ^ 0x80)
            }
        }
        return Data(output)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}
