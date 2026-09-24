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
        let highlightRanges = annotations.compactMap { annotation -> (NSRange, ExistingHighlight)? in
            guard let range = textRange(from: annotation.locator), range.length > 0 else { return nil }
            return (range, ExistingHighlight(id: annotation.id, hasNote: !annotation.note.isEmpty))
        }
        (textView as? LeafTextView)?.highlightAt = { index in
            highlightRanges.first { NSLocationInRange(index, $0.0) }?.1
        }
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
                        Coordinator.scroll(characterIndex: clamped.location, toTopOf: textView)
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
            // The first line visible below the toolbar, which the text scrolls under.
            let top = clipView.bounds.minY + clipView.contentInsets.top
            let charIndex = Self.characterIndex(atY: top, in: textView)
            positionSaveTask?.cancel()
            positionSaveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.persistPosition(charIndex: charIndex)
            }
        }

        /// Scrolls so the line holding a character sits just below the toolbar,
        /// where `characterIndex(atY:in:)` reads the position back.
        static func scroll(characterIndex: Int, toTopOf textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let clipView = textView.enclosingScrollView?.contentView
            else { return }
            layoutManager.ensureLayout(for: textContainer)
            let glyph = layoutManager.glyphIndexForCharacter(at: characterIndex)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            // The opening line keeps the page's top margin in view.
            let y = characterIndex == 0
                ? -clipView.contentInsets.top
                : line.minY + textView.textContainerOrigin.y - clipView.contentInsets.top
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: y))
            textView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }

        /// The character starting the line at a height in the text view.
        static func characterIndex(atY y: CGFloat, in textView: NSTextView) -> Int {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer
            else { return 0 }
            let point = NSPoint(x: 0, y: max(0, y - textView.textContainerOrigin.y))
            let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
            return layoutManager.characterIndexForGlyph(at: glyph)
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
        noteAction: Selector,
        askAIAction: Selector
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

        let askItem = NSMenuItem(
            title: "Ask AI About This",
            action: askAIAction,
            keyEquivalent: ""
        )
        askItem.target = target
        menu.insertItem(askItem, at: 0)

        let noteItem = NSMenuItem(
            title: "Highlight with Note",
            action: noteAction,
            keyEquivalent: ""
        )
        noteItem.target = target
        menu.insertItem(noteItem, at: 0)
        menu.insertItem(highlightItem, at: 0)
    }

    /// Items for right-clicking an existing highlight with no selection.
    static func insertExisting(
        _ highlight: ExistingHighlight,
        into menu: NSMenu,
        target: AnyObject,
        noteAction: Selector,
        removeAction: Selector
    ) {
        let note = NSMenuItem(
            title: highlight.hasNote ? "Edit Note" : "Add Note",
            action: noteAction,
            keyEquivalent: ""
        )
        note.target = target
        note.representedObject = highlight.id
        let remove = NSMenuItem(title: "Remove Highlight", action: removeAction, keyEquivalent: "")
        remove.target = target
        remove.representedObject = highlight.id
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(remove, at: 0)
        menu.insertItem(note, at: 0)
    }

    static func color(from sender: NSMenuItem) -> HighlightColor {
        guard let rawValue = sender.representedObject as? String else {
            return .amber
        }
        return HighlightColor(rawValue: rawValue) ?? .amber
    }
}

struct ExistingHighlight {
    let id: UUID
    let hasNote: Bool
}

/// Highlight, note, and AI actions offered just above the start of a finished
/// selection, in a small solid panel of Leaf's own rather than a system
/// popover, which draws a translucent material and repositions itself.
@MainActor
final class SelectionActionsPresenter {
    private var panel: NSPanel?
    private var monitor: Any?

    /// Shows the bar just above the selection's first letter so the passage
    /// stays readable, or below its last line when there is no room above.
    /// Both rects are in screen coordinates.
    func show(firstLine: NSRect, lastLine: NSRect, in view: NSView) {
        close()
        guard let window = view.window else { return }
        let content = SelectionActionsHostingView(
            rootView: SelectionActionsBar(arrowX: 0, arrowOnTop: false) { [weak self] in self?.close() }
        )
        let size = content.fittingSize
        let gap: CGFloat = 2
        let bounds = window.frame
        // The arrow points at the first letter; the bar starts just left of it.
        let letterX = firstLine.minX + 4
        var origin = NSPoint(x: letterX - 24, y: firstLine.maxY + gap)
        var arrowOnTop = false
        if origin.y + size.height > bounds.maxY - 52 {
            origin.y = lastLine.minY - gap - size.height
            arrowOnTop = true
        }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        let arrowX = min(max(letterX - origin.x, 18), size.width - 18)
        content.rootView = SelectionActionsBar(arrowX: arrowX, arrowOnTop: arrowOnTop) { [weak self] in
            self?.close()
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        // Fade in while settling a few points toward the text.
        let rise: CGFloat = arrowOnTop ? -4 : 4
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - rise))
        window.addChildWindow(panel, ordered: .above)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }
        self.panel = panel

        // Any click, scroll, or key press elsewhere dismisses the bar.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            if event.window !== self?.panel { self?.close() }
            return event
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }
}

private final class SelectionActionsHostingView: NSHostingView<SelectionActionsBar> {
    // The panel never becomes key, so the first click must act.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct SelectionActionsBar: View {
    /// Where the arrow's tip sits, from the bar's leading edge.
    let arrowX: CGFloat
    /// Whether the arrow points up, when the bar sits below the selection.
    let arrowOnTop: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                SelectionActionButton(
                    help: color == .amber ? "Highlight \(color.displayName) (⇧⌘H)" : "Highlight \(color.displayName)"
                ) { isHovered in
                    Circle()
                        .fill(color.swiftUIColor)
                        .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                        .frame(width: 14, height: 14)
                        .scaleEffect(isHovered ? 1.12 : 1)
                        .frame(width: 28, height: 28)
                } action: {
                    post(.leafHighlight, color)
                }
                .accessibilityLabel("Highlight \(color.displayName)")
            }
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 18)
                .padding(.horizontal, 4)
            SelectionActionButton(help: "Highlight with Note (⇧⌘N)") { _ in
                Label("Note", systemImage: "note.text")
                    .padding(.horizontal, 9)
                    .frame(height: 28)
            } action: {
                post(.leafAddNote)
            }
            SelectionActionButton(help: "Ask AI About This (⇧⌘A)") { _ in
                Label("Ask AI", systemImage: "sparkles")
                    .padding(.horizontal, 9)
                    .frame(height: 28)
            } action: {
                post(.leafAskAI)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 5)
        .frame(height: 36)
        .padding(arrowOnTop ? .top : .bottom, SelectionBubble.arrowHeight)
        .background {
            let bubble = SelectionBubble(arrowX: arrowX, arrowOnTop: arrowOnTop)
            bubble.fill(Color(nsColor: .controlBackgroundColor))
            bubble.stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
        }
        .fixedSize()
    }

    private func post(_ name: Notification.Name, _ object: Any? = nil) {
        dismiss()
        NotificationCenter.default.post(name: name, object: object)
    }
}

/// A rounded bar with a small arrow pointing at the selection.
private struct SelectionBubble: Shape {
    static let arrowHeight: CGFloat = 7
    let arrowX: CGFloat
    let arrowOnTop: Bool

    func path(in rect: CGRect) -> Path {
        let h = Self.arrowHeight
        let r: CGFloat = 10
        let top = arrowOnTop ? rect.minY + h : rect.minY
        let bottom = arrowOnTop ? rect.maxY : rect.maxY - h
        let (left, right) = (rect.minX, rect.maxX)
        let x = min(max(rect.minX + arrowX, left + r + h), right - r - h)
        // One outline, so the arrow's base has no seam.
        var path = Path()
        path.move(to: CGPoint(x: left + r, y: top))
        if arrowOnTop {
            path.addLine(to: CGPoint(x: x - h, y: top))
            path.addLine(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x + h, y: top))
        }
        path.addLine(to: CGPoint(x: right - r, y: top))
        path.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: top + r), radius: r)
        path.addLine(to: CGPoint(x: right, y: bottom - r))
        path.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right - r, y: bottom), radius: r)
        if !arrowOnTop {
            path.addLine(to: CGPoint(x: x + h, y: bottom))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x - h, y: bottom))
        }
        path.addLine(to: CGPoint(x: left + r, y: bottom))
        path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: bottom - r), radius: r)
        path.addLine(to: CGPoint(x: left, y: top + r))
        path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left + r, y: top), radius: r)
        path.closeSubpath()
        return path
    }
}

/// A bar button whose background tints while the pointer is over it.
private struct SelectionActionButton<Label: View>: View {
    let help: String
    @ViewBuilder let label: (Bool) -> Label
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label(isHovered)
                .contentShape(Rectangle())
                .background(
                    Color.primary.opacity(isHovered ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .help(help)
    }
}

final class LeafTextView: NSTextView {
    var onResize: (() -> Void)?
    /// Finds the saved highlight covering a character index.
    var highlightAt: ((Int) -> ExistingHighlight?)?
    private let selectionActions = SelectionActionsPresenter()

    override func mouseDown(with event: NSEvent) {
        selectionActions.close()
        super.mouseDown(with: event)
        // NSTextView usually tracks the whole drag here; otherwise mouseUp follows.
        if NSEvent.pressedMouseButtons & 1 == 0 { showSelectionActions() }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        showSelectionActions()
    }

    private func showSelectionActions() {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length,
              !(string as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let window
        else { return }
        // The selection's first and last lines, in screen coordinates.
        guard let layoutManager, let textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textContainerOrigin
        var lines: [NSRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: textContainer
        ) { rect, _ in lines.append(rect.offsetBy(dx: origin.x, dy: origin.y)) }
        guard let first = lines.first, let last = lines.last,
              visibleRect.intersects(first.union(last))
        else { return }
        let screen = { (rect: NSRect) in window.convertToScreen(self.convert(rect, to: nil)) }
        selectionActions.show(firstLine: screen(first), lastLine: screen(last), in: self)
    }

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
                noteAction: #selector(addLeafNote),
                askAIAction: #selector(askAI)
            )
        } else {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if let highlight = highlightAt?(index) {
                LeafAnnotationContextMenu.insertExisting(
                    highlight, into: menu, target: self,
                    noteAction: #selector(editLeafNote(_:)),
                    removeAction: #selector(removeLeafHighlight(_:))
                )
            }
        }
        return menu
    }

    @objc private func editLeafNote(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .leafEditNote, object: sender.representedObject)
    }

    @objc private func removeLeafHighlight(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .leafRemoveHighlight, object: sender.representedObject)
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

    @objc private func askAI() {
        NotificationCenter.default.post(name: .leafAskAI, object: nil)
    }
}

final class LeafPDFView: PDFView {
    /// Whether the highlight with this ID has a note; nil when it is not Leaf's.
    var noteState: ((UUID) -> Bool?)?
    private let selectionActions = SelectionActionsPresenter()

    override func mouseDown(with event: NSEvent) {
        selectionActions.close()
        super.mouseDown(with: event)
        // PDFView may track the whole drag here, swallowing the mouse-up.
        if NSEvent.pressedMouseButtons & 1 == 0 { showSelectionActions() }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        showSelectionActions()
    }

    private func showSelectionActions() {
        guard let window,
              let selection = currentSelection,
              !(selection.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        else { return }
        // The selection's first and last lines, in screen coordinates.
        let lines = selection.selectionsByLine()
        guard let firstLine = lines.first, let firstPage = firstLine.pages.first,
              let lastLine = lines.last, let lastPage = lastLine.pages.last
        else { return }
        let first = convert(firstLine.bounds(for: firstPage), from: firstPage)
        let last = convert(lastLine.bounds(for: lastPage), from: lastPage)
        guard visibleRect.intersects(first.union(last)) else { return }
        let screen = { (rect: NSRect) in window.convertToScreen(self.convert(rect, to: nil)) }
        selectionActions.show(firstLine: screen(first), lastLine: screen(last), in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let quote = currentSelection?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !quote.isEmpty
        else {
            if let highlight = highlight(at: event) {
                LeafAnnotationContextMenu.insertExisting(
                    highlight, into: menu, target: self,
                    noteAction: #selector(editLeafNote(_:)),
                    removeAction: #selector(removeLeafHighlight(_:))
                )
            }
            return menu
        }

        LeafAnnotationContextMenu.insert(
            into: menu,
            target: self,
            highlightAction: #selector(addLeafHighlight(_:)),
            noteAction: #selector(addLeafNote),
            askAIAction: #selector(askAI)
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

    @objc private func askAI() {
        NotificationCenter.default.post(name: .leafAskAI, object: nil)
    }

    @objc private func editLeafNote(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .leafEditNote, object: sender.representedObject)
    }

    @objc private func removeLeafHighlight(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .leafRemoveHighlight, object: sender.representedObject)
    }

    private func highlight(at event: NSEvent) -> ExistingHighlight? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        for annotation in page.annotations where annotation.bounds.contains(pagePoint) {
            guard let contents = annotation.contents, contents.hasPrefix("leaf:"),
                  let id = UUID(uuidString: String(contents.dropFirst(5))),
                  let hasNote = noteState?(id)
            else { continue }
            return ExistingHighlight(id: id, hasNote: hasNote)
        }
        return nil
    }
}

struct PDFReaderView: NSViewRepresentable {
    @Environment(ReaderStore.self) private var store
    let url: URL
    let book: BookRecord
    let annotations: [AnnotationRecord]

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, book: book)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = LeafPDFView()
        view.document = PDFDocument(url: url)
        if let document = view.document { Self.softenSavedHighlights(in: document) }
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
        let notes = Dictionary(uniqueKeysWithValues: annotations.map { ($0.id, !$0.note.isEmpty) })
        (view as? LeafPDFView)?.noteState = { notes[$0] }
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

    /// Earlier versions saved Leaf highlights in their full color, which a
    /// PDF shows opaque. Display those with the light tint new ones use; the
    /// file itself is left alone.
    static func softenSavedHighlights(in document: PDFDocument) {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations
            where annotation.contents?.hasPrefix("leaf:") == true
                && annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Highlight" {
                let tint = HighlightColor.nearest(to: annotation.color).pdfHighlightColor
                if annotation.color.usingColorSpace(.sRGB) != tint { annotation.color = tint }
            }
        }
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
