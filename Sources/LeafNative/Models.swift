import Foundation
import SwiftData

enum ReaderFormat: String, Codable, CaseIterable, Sendable {
    case sample
    case pdf
    case epub
    case mobi
    case azw
    case azw3
    case fb2
    case cbz
    case cbr
    case txt
    case markdown = "md"
    case html
    case rtf
    case rtfd
    case doc
    case docx
    case unknown

    init(url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": self = .pdf
        case "epub": self = .epub
        case "mobi": self = .mobi
        case "azw": self = .azw
        case "azw3", "kf8": self = .azw3
        case "fb2": self = .fb2
        case "cbz": self = .cbz
        case "cbr": self = .cbr
        case "txt": self = .txt
        case "md", "markdown": self = .markdown
        case "html", "htm", "xhtml": self = .html
        case "rtf": self = .rtf
        case "rtfd": self = .rtfd
        case "doc": self = .doc
        case "docx": self = .docx
        default: self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .sample: "BOOK"
        case .markdown: "MD"
        default: rawValue.uppercased()
        }
    }

    var symbolName: String {
        switch self {
        case .pdf: "doc.richtext"
        case .cbz, .cbr: "photo.on.rectangle.angled"
        case .doc, .docx, .rtf, .rtfd: "doc.text"
        default: "book.closed"
        }
    }
}

enum HighlightColor: String, Codable, CaseIterable, Sendable {
    case amber
    case sage
    case rose

    var displayName: String {
        rawValue.capitalized
    }
}

enum CoverTone: String, Codable, CaseIterable, Sendable {
    case ochre
    case forest
    case clay
    case ink
    case linen
}

@Model
final class BookRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String
    var formatRaw: String
    var filePath: String
    var progress: Double
    var lastOpened: Date
    var currentChapter: String
    var lastLocator: String = ""
    var bookmarkLocator: String = ""
    var contentHash: String = ""
    var doi: String = ""
    var citationData: Data = Data()
    var coverToneRaw: String
    var isFavorite: Bool
    var isBookmarked: Bool

    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        format: ReaderFormat,
        filePath: String = "",
        progress: Double = 0,
        lastOpened: Date = .now,
        currentChapter: String = "Start reading",
        lastLocator: String = "",
        bookmarkLocator: String = "",
        contentHash: String = "",
        coverTone: CoverTone = .ochre,
        isFavorite: Bool = false,
        isBookmarked: Bool = false
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.formatRaw = format.rawValue
        self.filePath = filePath
        self.progress = progress
        self.lastOpened = lastOpened
        self.currentChapter = currentChapter
        self.lastLocator = lastLocator
        self.bookmarkLocator = bookmarkLocator
        self.contentHash = contentHash
        self.coverToneRaw = coverTone.rawValue
        self.isFavorite = isFavorite
        self.isBookmarked = isBookmarked
    }

    var format: ReaderFormat {
        get { ReaderFormat(rawValue: formatRaw) ?? .unknown }
        set { formatRaw = newValue.rawValue }
    }

    var coverTone: CoverTone {
        get { CoverTone(rawValue: coverToneRaw) ?? .ochre }
        set { coverToneRaw = newValue.rawValue }
    }

    var fileURL: URL? {
        filePath.isEmpty ? nil : URL(fileURLWithPath: filePath)
    }

    /// Bibliographic metadata confirmed through Crossref, if any.
    var citation: CitationMetadata? {
        get { citationData.isEmpty ? nil : try? JSONDecoder().decode(CitationMetadata.self, from: citationData) }
        set { citationData = newValue.flatMap { try? JSONEncoder().encode($0) } ?? Data() }
    }
}

@Model
final class AnnotationRecord {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var quote: String
    var note: String
    var colorRaw: String
    var locator: String
    var chapter: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        bookID: UUID,
        quote: String,
        note: String = "",
        color: HighlightColor = .amber,
        locator: String,
        chapter: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.bookID = bookID
        self.quote = quote
        self.note = note
        self.colorRaw = color.rawValue
        self.locator = locator
        self.chapter = chapter
        self.createdAt = createdAt
    }

    var color: HighlightColor {
        get { HighlightColor(rawValue: colorRaw) ?? .amber }
        set { colorRaw = newValue.rawValue }
    }
}

enum SidebarDestination: Hashable {
    case library
    case reader
    case highlights
    case favorites
}

struct BookContentEntry: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let locator: String
    let level: Int

    var pdfPageIndex: Int? {
        let parts = locator.split(separator: ":")
        guard parts.count == 2, parts[0] == "pdf" else { return nil }
        return Int(parts[1])
    }

    var textOffset: Int? {
        let parts = locator.split(separator: ":")
        guard parts.count == 3, parts[0] == "text" else { return nil }
        return Int(parts[1])
    }
}

enum LoadedBookContent: @unchecked Sendable {
    case attributedText(NSAttributedString)
    case epub(NSAttributedString, contents: [BookContentEntry])
    case pdf(URL)
    case comic([Data])
    case quickLook(URL)
    case unavailable(String)
}
