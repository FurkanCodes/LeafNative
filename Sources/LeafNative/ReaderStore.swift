import AppKit
import Observation
import PDFKit
import SwiftData
import SwiftUI

private enum PDFHighlightIdentity {
    static func tag(for annotationID: UUID) -> String {
        "leaf:\(annotationID.uuidString)"
    }

    @discardableResult
    static func remove(
        annotationID: UUID,
        quote: String,
        from page: PDFPage
    ) -> Int {
        let tag = tag(for: annotationID)
        let highlightType = PDFAnnotationSubtype.highlight.rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let highlights = page.annotations.filter {
            $0.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == highlightType
        }
        let tagged = highlights.filter { $0.contents == tag }
        let matches: [PDFAnnotation]

        if tagged.isEmpty {
            let normalizedQuote = normalize(quote)
            matches = highlights.filter { annotation in
                guard let fragment = page.selection(for: annotation.bounds)?.string else {
                    return false
                }
                let normalizedFragment = normalize(fragment)
                return normalizedFragment.count >= 3
                    && normalizedQuote.contains(normalizedFragment)
            }
        } else {
            matches = tagged
        }

        for annotation in matches {
            page.removeAnnotation(annotation)
        }
        return matches.count
    }

    private static func normalize(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

private actor PDFHighlightPersistence {
    struct Mark: Sendable {
        let pageIndex: Int
        let bounds: CGRect
    }

    static let shared = PDFHighlightPersistence()

    func save(
        marks: [Mark],
        color: HighlightColor,
        annotationID: UUID,
        to url: URL
    ) -> Bool {
        guard let document = PDFDocument(url: url) else { return false }

        for mark in marks {
            guard let page = document.page(at: mark.pageIndex) else { continue }
            let annotation = PDFAnnotation(
                bounds: mark.bounds,
                forType: .highlight,
                withProperties: nil
            )
            annotation.color = color.nsColor.withAlphaComponent(0.34)
            annotation.contents = PDFHighlightIdentity.tag(for: annotationID)
            page.addAnnotation(annotation)
        }

        return document.write(to: url)
    }

    func delete(
        annotationID: UUID,
        pageIndex: Int,
        quote: String,
        from url: URL
    ) -> Bool {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex)
        else { return false }

        PDFHighlightIdentity.remove(
            annotationID: annotationID,
            quote: quote,
            from: page
        )
        return document.write(to: url)
    }
}

@MainActor
@Observable
final class ReaderStore {
    struct LocationNavigation: Equatable {
        let requestID = UUID()
        let bookID: UUID
        let locator: String
    }

    var destination: SidebarDestination = .reader
    var selectedBook: BookRecord?
    var columnVisibility: NavigationSplitViewVisibility = .all
    var inspectorVisible = true
    var inspectorTab = 0
    var importerVisible = false
    var appearanceVisible = false
    var searchText = ""
    var loadedContent: LoadedBookContent?
    var contents: [BookContentEntry] = []
    var activeContentEntryID: String?
    var isLoading = false
    var loadingError: String?
    var selectedTextRange = NSRange(location: NSNotFound, length: 0)
    var selectedTextQuote = ""
    var activePDFView: PDFView?
    var locationNavigation: LocationNavigation?
    var toast: String?

    private enum Defaults {
        static let fontSize = "leaf.appearance.fontSize"
        static let lineSpacing = "leaf.appearance.lineSpacing"
        static let pageWidth = "leaf.appearance.pageWidth"
        static let theme = "leaf.appearance.theme"
        static let librarySort = "leaf.librarySort"
    }

    var fontSize: CGFloat {
        get {
            access(keyPath: \.fontSize)
            return (UserDefaults.standard.object(forKey: Defaults.fontSize) as? Double)
                .map { CGFloat($0) } ?? 18
        }
        set {
            withMutation(keyPath: \.fontSize) {
                UserDefaults.standard.set(Double(newValue), forKey: Defaults.fontSize)
            }
        }
    }

    var lineSpacing: CGFloat {
        get {
            access(keyPath: \.lineSpacing)
            return (UserDefaults.standard.object(forKey: Defaults.lineSpacing) as? Double)
                .map { CGFloat($0) } ?? 8
        }
        set {
            withMutation(keyPath: \.lineSpacing) {
                UserDefaults.standard.set(
                    Double(newValue),
                    forKey: Defaults.lineSpacing
                )
            }
        }
    }

    var pageWidth: CGFloat {
        get {
            access(keyPath: \.pageWidth)
            return (UserDefaults.standard.object(forKey: Defaults.pageWidth) as? Double)
                .map { CGFloat($0) } ?? 680
        }
        set {
            withMutation(keyPath: \.pageWidth) {
                UserDefaults.standard.set(Double(newValue), forKey: Defaults.pageWidth)
            }
        }
    }

    var readerTheme: ReaderTheme {
        get {
            access(keyPath: \.readerTheme)
            return UserDefaults.standard.string(forKey: Defaults.theme)
                .flatMap(ReaderTheme.init(rawValue:)) ?? .paper
        }
        set {
            withMutation(keyPath: \.readerTheme) {
                UserDefaults.standard.set(newValue.rawValue, forKey: Defaults.theme)
            }
        }
    }

    var librarySort: LibrarySort {
        get {
            access(keyPath: \.librarySort)
            return UserDefaults.standard.string(forKey: Defaults.librarySort)
                .flatMap(LibrarySort.init(rawValue:)) ?? .lastOpened
        }
        set {
            withMutation(keyPath: \.librarySort) {
                UserDefaults.standard.set(newValue.rawValue, forKey: Defaults.librarySort)
            }
        }
    }

    enum ReaderTheme: String, CaseIterable, Identifiable {
        case paper
        case sepia
        case night

        var id: Self { self }

        var label: String {
            rawValue.capitalized
        }
    }

    enum LibrarySort: String, CaseIterable, Identifiable {
        case lastOpened
        case title
        case author

        var id: Self { self }

        var label: String {
            switch self {
            case .lastOpened: "Last Opened"
            case .title: "Title"
            case .author: "Author"
            }
        }
    }

    func select(_ book: BookRecord) {
        selectedBook = book
        book.lastOpened = .now
        destination = .reader
        searchText = ""
        selectedTextRange = NSRange(location: NSNotFound, length: 0)
        selectedTextQuote = ""
        activePDFView = nil
        contents = []
        activeContentEntryID = nil
        locationNavigation = nil
    }

    func navigate(
        to annotation: AnnotationRecord,
        in book: BookRecord? = nil
    ) {
        if let book, selectedBook?.id != book.id {
            select(book)
        } else {
            destination = .reader
        }

        locationNavigation = LocationNavigation(
            bookID: annotation.bookID,
            locator: annotation.locator
        )
    }

    func setContents(_ entries: [BookContentEntry]) {
        contents = entries
        activeContentEntryID = entries.first?.id
    }

    func navigate(to entry: BookContentEntry) {
        guard let book = selectedBook else { return }
        destination = .reader
        activeContentEntryID = entry.id
        locationNavigation = LocationNavigation(
            bookID: book.id,
            locator: entry.locator
        )
    }

    func updateCurrentPDFSection(pageIndex: Int) -> String? {
        let current = contents.last {
            guard let entryPage = $0.pdfPageIndex else { return false }
            return entryPage <= pageIndex
        }
        activeContentEntryID = current?.id
        return current?.title
    }

    func updateCurrentTextSection(charIndex: Int) -> String? {
        let current = contents.last {
            guard let offset = $0.textOffset else { return false }
            return offset <= charIndex
        }
        activeContentEntryID = current?.id
        return current?.title
    }

    func toggleBookmark(on book: BookRecord) {
        book.isBookmarked.toggle()
        if book.isBookmarked {
            book.bookmarkLocator = book.lastLocator.isEmpty
                ? Self.startLocator(for: book.format)
                : book.lastLocator
        } else {
            book.bookmarkLocator = ""
        }
        showToast(book.isBookmarked ? "Page bookmarked" : "Bookmark removed")
    }

    private static func startLocator(for format: ReaderFormat) -> String {
        switch format {
        case .pdf:
            "pdf:0"
        case .cbz, .cbr, .unknown:
            ""
        default:
            "text:0:0"
        }
    }

    func navigateToBookmark(in book: BookRecord) {
        guard book.isBookmarked, !book.bookmarkLocator.isEmpty else { return }
        locationNavigation = LocationNavigation(
            bookID: book.id,
            locator: book.bookmarkLocator
        )
    }

    func showToast(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if toast == message {
                toast = nil
            }
        }
    }

    func previousPage() {
        if let pdfView = activePDFView {
            pdfView.goToPreviousPage(nil)
        }
    }

    func nextPage() {
        if let pdfView = activePDFView {
            pdfView.goToNextPage(nil)
        }
    }

    func addHighlight(
        color: HighlightColor,
        context: ModelContext
    ) {
        guard let book = selectedBook else { return }

        if book.format == .pdf, let pdfView = activePDFView,
           let selection = pdfView.currentSelection,
           let quote = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !quote.isEmpty {
            let recordID = UUID()
            var marks: [PDFHighlightPersistence.Mark] = []
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let bounds = line.bounds(for: page)
                    let annotation = PDFAnnotation(
                        bounds: bounds,
                        forType: .highlight,
                        withProperties: nil
                    )
                    annotation.color = color.nsColor.withAlphaComponent(0.34)
                    annotation.contents = PDFHighlightIdentity.tag(for: recordID)
                    page.addAnnotation(annotation)

                    if let document = pdfView.document {
                        marks.append(
                            PDFHighlightPersistence.Mark(
                                pageIndex: document.index(for: page),
                                bounds: bounds
                            )
                        )
                    }
                }
            }

            let pageIndex = selection.pages.first.flatMap {
                pdfView.document?.index(for: $0)
            } ?? 0
            let record = AnnotationRecord(
                id: recordID,
                bookID: book.id,
                quote: quote,
                color: color,
                locator: "pdf:\(pageIndex)",
                chapter: book.currentChapter
            )
            context.insert(record)
            if let url = book.fileURL {
                Task {
                    let didSave = await PDFHighlightPersistence.shared.save(
                        marks: marks,
                        color: color,
                        annotationID: recordID,
                        to: url
                    )
                    if !didSave {
                        showToast("Highlight saved, but the PDF could not be updated")
                    }
                }
            }
            pdfView.clearSelection()
            showToast("Highlight saved")
            return
        }

        guard selectedTextRange.location != NSNotFound,
              selectedTextRange.length > 0,
              !selectedTextQuote.isEmpty
        else {
            showToast("Select text first")
            return
        }

        let record = AnnotationRecord(
            bookID: book.id,
            quote: selectedTextQuote,
            color: color,
            locator: "text:\(selectedTextRange.location):\(selectedTextRange.length)",
            chapter: book.currentChapter
        )
        context.insert(record)
        selectedTextRange = NSRange(location: NSNotFound, length: 0)
        selectedTextQuote = ""
        showToast("Highlight saved")
    }

    func deleteHighlight(
        _ annotation: AnnotationRecord,
        context: ModelContext
    ) {
        let annotationID = annotation.id
        let quote = annotation.quote
        let locator = annotation.locator

        if let book = selectedBook,
           book.id == annotation.bookID,
           book.format == .pdf,
           let pageIndex = pdfPageIndex(from: locator) {
            if let page = activePDFView?.document?.page(at: pageIndex) {
                PDFHighlightIdentity.remove(
                    annotationID: annotationID,
                    quote: quote,
                    from: page
                )
            }

            if let url = book.fileURL {
                Task {
                    let didDelete = await PDFHighlightPersistence.shared.delete(
                        annotationID: annotationID,
                        pageIndex: pageIndex,
                        quote: quote,
                        from: url
                    )
                    if !didDelete {
                        showToast("Highlight removed, but the PDF could not be updated")
                    }
                }
            }
        }

        context.delete(annotation)
        showToast("Highlight deleted")
    }

    func addNote(context: ModelContext) {
        addHighlight(color: .amber, context: context)
        inspectorVisible = true
        inspectorTab = 1
    }

    private func pdfPageIndex(from locator: String) -> Int? {
        let parts = locator.split(separator: ":")
        guard parts.count == 2, parts[0] == "pdf" else { return nil }
        return Int(parts[1])
    }
}

extension HighlightColor {
    var nsColor: NSColor {
        switch self {
        case .amber: NSColor(red: 0.88, green: 0.64, blue: 0.23, alpha: 1)
        case .sage: NSColor(red: 0.43, green: 0.52, blue: 0.40, alpha: 1)
        case .rose: NSColor(red: 0.67, green: 0.40, blue: 0.36, alpha: 1)
        }
    }

    var swiftUIColor: Color {
        Color(nsColor: nsColor)
    }
}
