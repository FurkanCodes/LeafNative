import AppKit
import PDFKit
import Quartz
import SwiftUI

struct NativeTextReader: NSViewRepresentable {
    @Environment(ReaderStore.self) private var store
    let content: NSAttributedString
    let annotations: [AnnotationRecord]
    let book: BookRecord

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, book: book)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.scrollerStyle = .overlay

        let textView = LeafTextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isRichText = true
        textView.importsGraphics = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 64, height: 74)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.onResize = { [weak textView, weak scrollView] in
            guard let textView, let scrollView else { return }
            NativeTextReader.updateInsets(
                textView: textView,
                contentWidth: scrollView.contentSize.width,
                pageWidth: store.pageWidth
            )
        }

        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.positionSaveTask?.cancel()
        NotificationCenter.default.removeObserver(
            coordinator,
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        let styleSignature = Coordinator.StyleSignature(
            contentIdentity: ObjectIdentifier(content),
            fontSize: store.fontSize,
            lineSpacing: store.lineSpacing,
            theme: store.readerTheme,
            isSample: book.format == .sample
        )
        let annotationSnapshots = Dictionary(
            uniqueKeysWithValues: annotations.map {
                (
                    $0.id,
                    Coordinator.AnnotationSnapshot(
                        locator: $0.locator,
                        color: $0.color
                    )
                )
            }
        )

        context.coordinator.book = book
        if context.coordinator.styleSignature != styleSignature {
            context.coordinator.styleSignature = styleSignature
            context.coordinator.annotationSnapshots = annotationSnapshots
            textView.textStorage?.setAttributedString(
                styledContent(
                    source: content,
                    annotations: annotations,
                    store: store,
                    isSample: book.format == .sample
                )
            )
            if context.coordinator.restoredBookID != book.id {
                context.coordinator.restoredBookID = book.id
                if let range = textRange(from: book.lastLocator),
                   range.location < (textView.textStorage?.length ?? 0) {
                    let storageLength = textView.textStorage?.length ?? 0
                    let clamped = NSRange(
                        location: range.location,
                        length: min(range.length, storageLength - range.location)
                    )
                    Task { @MainActor in
                        textView.scrollRangeToVisible(clamped)
                    }
                }
            }
        } else if context.coordinator.annotationSnapshots != annotationSnapshots {
            updateHighlights(
                in: textView,
                previous: context.coordinator.annotationSnapshots,
                annotations: annotations,
                store: store
            )
            context.coordinator.annotationSnapshots = annotationSnapshots
        }

        scrollView.backgroundColor = store.readerTheme.nsBackground
        textView.backgroundColor = store.readerTheme.nsBackground
        textView.insertionPointColor = store.readerTheme.nsForeground
        Self.updateInsets(
            textView: textView,
            contentWidth: scrollView.contentSize.width,
            pageWidth: store.pageWidth
        )

        if context.coordinator.lastSearch != store.searchText {
            context.coordinator.lastSearch = store.searchText
            performSearch(store.searchText, in: textView)
        }

        if let navigation = store.locationNavigation,
           navigation.bookID == book.id,
           context.coordinator.lastNavigationRequest != navigation.requestID {
            context.coordinator.lastNavigationRequest = navigation.requestID
            navigate(to: navigation.locator, in: textView)
        }
    }

    static func updateInsets(
        textView: NSTextView,
        contentWidth: CGFloat,
        pageWidth: CGFloat
    ) {
        let horizontal = max(44, (contentWidth - pageWidth) / 2)
        textView.textContainerInset = NSSize(width: horizontal, height: 74)
    }

    private func styledContent(
        source: NSAttributedString,
        annotations: [AnnotationRecord],
        store: ReaderStore,
        isSample: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: result.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = store.lineSpacing
        paragraph.paragraphSpacing = store.fontSize * 0.68
        paragraph.lineBreakMode = .byWordWrapping

        let readerFont = NSFont(
            name: "New York",
            size: store.fontSize
        ) ?? NSFont.systemFont(ofSize: store.fontSize)

        result.addAttributes([
            .font: readerFont,
            .foregroundColor: store.readerTheme.nsForeground,
            .paragraphStyle: paragraph,
        ], range: fullRange)

        if isSample {
            styleSample(result, store: store)
        }

        for annotation in annotations {
            guard let range = textRange(from: annotation.locator),
                  NSMaxRange(range) <= result.length
            else { continue }
            result.addAttribute(
                .backgroundColor,
                value: annotation.color.nsColor.withAlphaComponent(
                    store.readerTheme == .night ? 0.46 : 0.32
                ),
                range: range
            )
        }
        return result
    }

    private func updateHighlights(
        in textView: NSTextView,
        previous: [UUID: Coordinator.AnnotationSnapshot],
        annotations: [AnnotationRecord],
        store: ReaderStore
    ) {
        guard let textStorage = textView.textStorage else { return }

        textStorage.beginEditing()
        defer { textStorage.endEditing() }

        for snapshot in previous.values {
            guard let range = textRange(from: snapshot.locator),
                  NSMaxRange(range) <= textStorage.length
            else { continue }
            textStorage.removeAttribute(.backgroundColor, range: range)
        }

        for annotation in annotations {
            guard let range = textRange(from: annotation.locator),
                  NSMaxRange(range) <= textStorage.length
            else { continue }
            textStorage.addAttribute(
                .backgroundColor,
                value: annotation.color.nsColor.withAlphaComponent(
                    store.readerTheme == .night ? 0.46 : 0.32
                ),
                range: range
            )
        }
    }

    private func styleSample(
        _ text: NSMutableAttributedString,
        store: ReaderStore
    ) {
        let source = text.string as NSString
        let chapterLabel = source.range(of: "CHAPTER FOUR")
        let title = source.range(of: "A Practice of Noticing")
        let subtitle = source.range(
            of: "Attention is less like a spotlight and more like a room we learn to inhabit."
        )

        if chapterLabel.location != NSNotFound {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacing = 22
            text.addAttributes([
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: HighlightColor.amber.nsColor,
                .kern: 1.1,
                .paragraphStyle: style,
            ], range: chapterLabel)
        }
        if title.location != NSNotFound {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacing = 16
            text.addAttributes([
                .font: NSFont(name: "New York", size: 44)
                    ?? NSFont.systemFont(ofSize: 44, weight: .medium),
                .paragraphStyle: style,
                .kern: -1.2,
            ], range: title)
        }
        if subtitle.location != NSNotFound {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacing = 52
            text.addAttributes([
                .font: NSFont(
                    descriptor: (
                        NSFont(name: "New York", size: store.fontSize - 1)
                            ?? NSFont.systemFont(ofSize: store.fontSize - 1)
                    ).fontDescriptor.withSymbolicTraits(.italic),
                    size: store.fontSize - 1
                ) as Any,
                .foregroundColor: store.readerTheme.nsForeground.withAlphaComponent(0.68),
                .paragraphStyle: style,
            ], range: subtitle)
        }

        for heading in ["THE INTERVAL BEFORE JUDGMENT", "MAKE A PLACE FOR RETURN"] {
            let range = source.range(of: heading)
            guard range.location != NSNotFound else { continue }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 34
            style.paragraphSpacing = 14
            text.addAttributes([
                .font: NSFont(name: "New York", size: store.fontSize + 5)
                    ?? NSFont.systemFont(ofSize: store.fontSize + 5, weight: .semibold),
                .paragraphStyle: style,
            ], range: range)
        }
    }

    private func textRange(from locator: String) -> NSRange? {
        let parts = locator.split(separator: ":")
        guard parts.count == 3,
              parts[0] == "text",
              let location = Int(parts[1]),
              let length = Int(parts[2])
        else {
            return nil
        }
        return NSRange(location: location, length: length)
    }

    private func performSearch(_ query: String, in textView: NSTextView) {
        guard !query.isEmpty else { return }
        let range = (textView.string as NSString).range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        )
        guard range.location != NSNotFound else { return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    private func navigate(to locator: String, in textView: NSTextView) {
        guard let range = textRange(from: locator),
              NSMaxRange(range) <= (textView.string as NSString).length
        else { return }
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        struct StyleSignature: Equatable {
            let contentIdentity: ObjectIdentifier
            let fontSize: CGFloat
            let lineSpacing: CGFloat
            let theme: ReaderStore.ReaderTheme
            let isSample: Bool
        }

        struct AnnotationSnapshot: Equatable {
            let locator: String
            let color: HighlightColor
        }

        let store: ReaderStore
        var book: BookRecord
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var styleSignature: StyleSignature?
        var annotationSnapshots: [UUID: AnnotationSnapshot] = [:]
        var lastSearch = ""
        var lastNavigationRequest: UUID?
        var restoredBookID: UUID?
        var positionSaveTask: Task<Void, Never>?

        init(store: ReaderStore, book: BookRecord) {
            self.store = store
            self.book = book
        }

        @objc func boundsChanged(_ notification: Notification) {
            guard let textView,
                  let clipView = notification.object as? NSClipView
            else { return }
            guard restoredBookID == book.id || book.lastLocator.isEmpty else {
                return
            }
            let charIndex = textView.characterIndexForInsertion(
                at: clipView.bounds.origin
            )
            positionSaveTask?.cancel()
            positionSaveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.persistPosition(charIndex: charIndex)
            }
        }

        private func persistPosition(charIndex: Int) {
            guard charIndex >= 0 else { return }
            restoredBookID = book.id
            book.lastLocator = "text:\(charIndex):0"
            let total = max(1, textView?.textStorage?.length ?? 1)
            book.progress = min(1, Double(charIndex) / Double(total))
            if let section = store.updateCurrentTextSection(charIndex: charIndex) {
                book.currentChapter = section
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let range = textView.selectedRange()
            store.selectedTextRange = range
            if range.location != NSNotFound,
               range.length > 0,
               NSMaxRange(range) <= (textView.string as NSString).length {
                store.selectedTextQuote = (
                    textView.string as NSString
                ).substring(with: range)
            } else {
                store.selectedTextQuote = ""
            }
        }
    }
}

private enum LeafAnnotationContextMenu {
    static func insert(
        into menu: NSMenu,
        target: AnyObject,
        highlightAction: Selector,
        noteAction: Selector
    ) {
        let highlightItem = NSMenuItem(
            title: "Highlight",
            action: nil,
            keyEquivalent: ""
        )
        let highlightMenu = NSMenu(title: "Highlight")

        for color in HighlightColor.allCases {
            let colorItem = NSMenuItem(
                title: color.displayName,
                action: highlightAction,
                keyEquivalent: ""
            )
            colorItem.target = target
            colorItem.representedObject = color.rawValue
            colorItem.image = NSImage(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "\(color.displayName) highlight"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [color.nsColor])
            )
            highlightMenu.addItem(colorItem)
        }

        highlightItem.submenu = highlightMenu
        menu.insertItem(.separator(), at: 0)

        let noteItem = NSMenuItem(
            title: "Highlight with Note",
            action: noteAction,
            keyEquivalent: ""
        )
        noteItem.target = target
        menu.insertItem(noteItem, at: 0)
        menu.insertItem(highlightItem, at: 0)
    }

    static func color(from sender: NSMenuItem) -> HighlightColor {
        guard let rawValue = sender.representedObject as? String else {
            return .amber
        }
        return HighlightColor(rawValue: rawValue) ?? .amber
    }
}

final class LeafTextView: NSTextView {
    var onResize: (() -> Void)?

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onResize?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if selectedRange().length > 0 {
            LeafAnnotationContextMenu.insert(
                into: menu,
                target: self,
                highlightAction: #selector(addLeafHighlight(_:)),
                noteAction: #selector(addLeafNote)
            )
        }
        return menu
    }

    @objc private func addLeafHighlight(_ sender: NSMenuItem) {
        NotificationCenter.default.post(
            name: .leafHighlight,
            object: LeafAnnotationContextMenu.color(from: sender)
        )
    }

    @objc private func addLeafNote() {
        NotificationCenter.default.post(name: .leafAddNote, object: nil)
    }
}

final class LeafPDFView: PDFView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let quote = currentSelection?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !quote.isEmpty
        else {
            return menu
        }

        LeafAnnotationContextMenu.insert(
            into: menu,
            target: self,
            highlightAction: #selector(addLeafHighlight(_:)),
            noteAction: #selector(addLeafNote)
        )
        return menu
    }

    @objc private func addLeafHighlight(_ sender: NSMenuItem) {
        NotificationCenter.default.post(
            name: .leafHighlight,
            object: LeafAnnotationContextMenu.color(from: sender)
        )
    }

    @objc private func addLeafNote() {
        NotificationCenter.default.post(name: .leafAddNote, object: nil)
    }
}

struct PDFReaderView: NSViewRepresentable {
    @Environment(ReaderStore.self) private var store
    let url: URL
    let book: BookRecord

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, book: book)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = LeafPDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = store.readerTheme.nsBackground
        store.activePDFView = view

        if let pageIndex = Self.pageIndex(from: book.lastLocator),
           let page = view.document?.page(at: pageIndex) {
            Task { @MainActor in
                view.go(to: page)
            }
        }

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.book = book
        view.backgroundColor = store.readerTheme.nsBackground
        if store.activePDFView !== view {
            store.activePDFView = view
        }
        if !store.searchText.isEmpty {
            view.document?.beginFindString(
                store.searchText,
                withOptions: [.caseInsensitive]
            )
        }
        if let navigation = store.locationNavigation,
           navigation.bookID == book.id,
           context.coordinator.lastNavigationRequest != navigation.requestID {
            context.coordinator.lastNavigationRequest = navigation.requestID
            navigate(to: navigation.locator, in: view)
        }
    }

    private static func pageIndex(from locator: String) -> Int? {
        let parts = locator.split(separator: ":")
        guard parts.count == 2, parts[0] == "pdf" else { return nil }
        return Int(parts[1])
    }

    private func navigate(to locator: String, in view: PDFView) {
        let parts = locator.split(separator: ":")
        guard parts.count == 2,
              parts[0] == "pdf",
              let pageIndex = Int(parts[1]),
              let page = view.document?.page(at: pageIndex)
        else { return }
        view.go(to: page)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject {
        let store: ReaderStore
        var book: BookRecord
        var lastNavigationRequest: UUID?

        init(store: ReaderStore, book: BookRecord) {
            self.store = store
            self.book = book
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView,
                  let document = view.document,
                  let page = view.currentPage
            else { return }
            let index = document.index(for: page)
            let count = max(1, document.pageCount)
            book.progress = Double(index + 1) / Double(count)
            book.lastLocator = "pdf:\(index)"
            if let section = store.updateCurrentPDFSection(pageIndex: index) {
                book.currentChapter = "\(section) · Page \(index + 1) of \(count)"
            } else {
                book.currentChapter = "Page \(index + 1) of \(count)"
            }
        }
    }
}

struct ComicReaderView: View {
    let images: [Data]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                    if let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 900)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct QuickLookReaderView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)
        view?.previewItem = url as NSURL
        return view ?? QLPreviewView(frame: .zero, style: .normal)!
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
    }
}
