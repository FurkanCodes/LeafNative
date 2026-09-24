import SwiftData
import SwiftUI

// MARK: - Locations

enum AnnotationLocation {
    /// Sort key that orders PDF pages and text offsets as they appear in the book.
    static func position(_ locator: String) -> (Int, Int) {
        let parts = locator.split(separator: ":")
        if parts.first == "pdf", parts.count == 2 { return (Int(parts[1]) ?? .max, 0) }
        if parts.first == "text", parts.count == 3 { return (0, Int(parts[1]) ?? .max) }
        return (.max, .max)
    }

    /// One-based page number for PDF locators.
    static func page(_ locator: String) -> Int? {
        let parts = locator.split(separator: ":")
        guard parts.count == 2, parts[0] == "pdf", let index = Int(parts[1]) else { return nil }
        return index + 1
    }

    static func sortedForReading(_ annotations: [AnnotationRecord]) -> [AnnotationRecord] {
        annotations.sorted { left, right in
            let (a, b) = (position(left.locator), position(right.locator))
            return a == b ? left.createdAt < right.createdAt : a < b
        }
    }
}

enum AnnotationAnchoring {
    /// A corrected `text:` locator when the stored range no longer covers the
    /// highlighted quote, pointing at the occurrence nearest the old position.
    /// Returns nil when the locator is already right or the quote is gone.
    static func repairedLocator(_ locator: String, quote: String, in text: NSString) -> String? {
        let parts = locator.split(separator: ":")
        guard parts.count == 3, parts[0] == "text",
              let start = Int(parts[1]), let length = Int(parts[2]),
              length > 0, !quote.isEmpty
        else { return nil }
        let stored = NSRange(location: start, length: length)
        if NSMaxRange(stored) <= text.length, text.substring(with: stored) == quote { return nil }

        // Older highlights stored a sentence's final punctuation that the text lacks.
        let trimmed = quote.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?").union(.whitespaces))
        for candidate in [quote, trimmed] where !candidate.isEmpty {
            if let range = nearest(candidate, to: start, in: text) {
                return "text:\(range.location):\(range.length)"
            }
        }
        return nil
    }

    private static func nearest(_ quote: String, to start: Int, in text: NSString) -> NSRange? {
        var best: NSRange?
        var search = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: quote, options: [], range: search)
            guard found.location != NSNotFound else { break }
            if best == nil || abs(found.location - start) < abs(best!.location - start) { best = found }
            let next = found.location + 1
            guard next < text.length else { break }
            search = NSRange(location: next, length: text.length - next)
        }
        return best
    }
}

// MARK: - Sections

enum NotebookFilter: Hashable {
    case all
    case notes
    case color(HighlightColor)

    var label: String {
        switch self {
        case .all: "All Entries"
        case .notes: "With Notes"
        case .color(let color): color.displayName
        }
    }

    func includes(_ annotation: AnnotationRecord) -> Bool {
        switch self {
        case .all: true
        case .notes: !annotation.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .color(let color): !annotation.quote.isEmpty && annotation.color == color
        }
    }
}

struct NotebookSection: Identifiable {
    let title: String
    let annotations: [AnnotationRecord]
    var id: String { title }
}

enum NotebookSections {
    static let untitled = "This Book"

    /// The contents entry an annotation falls under, else the chapter it was
    /// written in. PDF chapters are stored as "Section · Page 3 of 20".
    static func title(locator: String, chapter: String, contents: [BookContentEntry]) -> String {
        let (page, offset) = AnnotationLocation.position(locator)
        let entry: BookContentEntry? = if locator.hasPrefix("pdf:") {
            contents.last { ($0.pdfPageIndex ?? .max) <= page }
        } else if locator.hasPrefix("text:") {
            contents.last { ($0.textOffset ?? .max) <= offset }
        } else {
            nil
        }
        if let entry { return SectionTitle.display(entry.title) }

        let section = chapter.components(separatedBy: " · Page ").first ?? ""
        let trimmed = section.trimmingCharacters(in: .whitespaces)
        if NotesMarkdown.placeholderChapters.contains(trimmed) || trimmed.hasPrefix("Page ") {
            return untitled
        }
        return SectionTitle.display(trimmed.replacingOccurrences(
            of: #"^\d+\.\s*"#, with: "", options: .regularExpression
        ))
    }

    /// Entries the filter and search leave visible. The entry being written
    /// always stays, so a new note is never hidden while it is empty.
    static func matching(
        _ annotations: [AnnotationRecord],
        filter: NotebookFilter,
        query: String,
        editingID: UUID?
    ) -> [AnnotationRecord] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return annotations.filter { annotation in
            if annotation.id == editingID { return true }
            guard filter.includes(annotation) else { return false }
            guard !query.isEmpty else { return true }
            return annotation.quote.localizedStandardContains(query)
                || annotation.note.localizedStandardContains(query)
        }
    }

    /// Annotations in reading order, grouped by consecutive section.
    static func build(_ annotations: [AnnotationRecord], contents: [BookContentEntry]) -> [NotebookSection] {
        var sections: [(title: String, annotations: [AnnotationRecord])] = []
        for annotation in AnnotationLocation.sortedForReading(annotations) {
            let title = title(locator: annotation.locator, chapter: annotation.chapter, contents: contents)
            if let last = sections.indices.last, sections[last].title == title {
                sections[last].annotations.append(annotation)
            } else if let existing = sections.firstIndex(where: { $0.title == title }) {
                // A section interrupted by an out-of-place entry stays one group.
                sections[existing].annotations.append(annotation)
            } else {
                sections.append((title, [annotation]))
            }
        }
        return sections.map { NotebookSection(title: $0.title, annotations: $0.annotations) }
    }

    /// How many of the ordered annotations come at or before the reading
    /// position, or nil when the position is unknown.
    static func readingMarkerIndex(in ordered: [AnnotationRecord], readingLocator: String) -> Int? {
        let current = AnnotationLocation.position(readingLocator)
        guard current != (.max, .max) else { return nil }
        return ordered.filter { AnnotationLocation.position($0.locator) <= current }.count
    }
}

// MARK: - Notebook

struct NotebookInspector: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    let annotations: [AnnotationRecord]
    @State private var selectedID: UUID?
    @State private var collapsed: Set<String> = []
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    if sections.isEmpty {
                        emptyState
                    } else {
                        entries
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(.downArrow) { moveSelection(by: 1, proxy: proxy) }
                .onKeyPress(.upArrow) { moveSelection(by: -1, proxy: proxy) }
                .onKeyPress(.return, phases: .down) { press in
                    // This handler sees Return before the note editor does,
                    // so it also saves the open note; Shift-Return adds a line.
                    if let id = store.editingAnnotationID {
                        guard !press.modifiers.contains(.shift),
                              let editing = annotations.first(where: { $0.id == id })
                        else { return .ignored }
                        store.finishEditingNote(editing, context: modelContext)
                        selectedID = id
                        DispatchQueue.main.async { listFocused = true }
                        return .handled
                    }
                    guard let annotation = selectedAnnotation else { return .ignored }
                    store.beginEditingNote(annotation)
                    return .handled
                }
                .onDeleteCommand {
                    if store.editingAnnotationID == nil, let annotation = selectedAnnotation {
                        store.deleteHighlight(annotation, context: modelContext)
                    }
                }
                .onChange(of: store.editingAnnotationID) { _, id in
                    if let id { reveal(id, proxy: proxy) }
                }
                .onChange(of: annotations.map(\.id)) { old, new in
                    // Bring a newly added highlight or note into view.
                    let added = Set(new).subtracting(old)
                    guard added.count == 1, let id = added.first else { return }
                    reveal(id, proxy: proxy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: store.selectedBook?.id) {
            selectedID = nil
            collapsed = []
        }
    }

    // MARK: Search and filter

    private var searchBar: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search highlights and notes", text: $store.notebookQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !store.notebookQuery.isEmpty {
                    Button {
                        store.notebookQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear Search")
                }
                Menu {
                    Picker("Show", selection: $store.notebookFilter) {
                        Text(NotebookFilter.all.label).tag(NotebookFilter.all)
                        Text(NotebookFilter.notes.label).tag(NotebookFilter.notes)
                        Divider()
                        ForEach(HighlightColor.allCases, id: \.self) { color in
                            Text(color.displayName).tag(NotebookFilter.color(color))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(store.notebookFilter == .all ? AnyShapeStyle(.secondary) : AnyShapeStyle(LeafPalette.amberText))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filter Entries")
                .accessibilityLabel("Filter entries")
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(height: 28)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))

            if store.notebookFilter != .all {
                HStack(spacing: 8) {
                    Text("\(store.notebookFilter.label) · \(visibleCount) of \(annotations.count)")
                        .foregroundStyle(.secondary)
                    Button("Clear") { store.notebookFilter = .all }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                        .foregroundStyle(LeafPalette.amberText)
                }
                .font(.caption)
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: Entries

    private var entries: some View {
        let marker = readingMarker
        return LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
            ForEach(sections) { section in
                let isOpen = !collapsed.contains(section.title)
                Section {
                    if isOpen {
                        ForEach(section.annotations) { annotation in
                            if marker.before == annotation.id { ReadingMarker() }
                            NotebookEntryRow(
                                annotation: annotation,
                                isSelected: selectedID == annotation.id,
                                select: {
                                    selectedID = annotation.id
                                    listFocused = true
                                },
                                returnFocus: {
                                    // Keep this entry selected, not whichever
                                    // view the closing editor would hand focus to.
                                    selectedID = annotation.id
                                    DispatchQueue.main.async { listFocused = true }
                                }
                            )
                            .id(annotation.id)
                        }
                        if marker.atEnd, section.id == sections.last?.id { ReadingMarker() }
                    }
                } header: {
                    sectionHeader(section, isOpen: isOpen)
                }
            }
        }
        .padding(.bottom, 48)
    }

    private func sectionHeader(_ section: NotebookSection, isOpen: Bool) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                if isOpen { collapsed.insert(section.title) } else { collapsed.remove(section.title) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                Text(section.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(section.annotations.count, format: .number)
                    .fontWeight(.regular)
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
            .padding(.trailing, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(LeafPalette.notebook)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.title), \(section.annotations.count) entries")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if annotations.isEmpty {
                Text("Nothing in your notebook yet")
                    .font(.callout.weight(.semibold))
                Text("Select text and press ⇧⌘H to highlight it, or ⇧⌘N to write a note. Everything you mark appears here in reading order.")
            } else {
                Text("No matches")
                    .font(.callout.weight(.semibold))
                if store.notebookQuery.isEmpty {
                    Text("No entries match this filter.")
                } else {
                    Text("Nothing in this book’s notebook matches “\(store.notebookQuery)”.")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 270)
        .padding(.vertical, 64)
        .frame(maxWidth: .infinity)
    }

    // MARK: Model

    private var matchingAnnotations: [AnnotationRecord] {
        NotebookSections.matching(
            annotations,
            filter: store.notebookFilter,
            query: store.notebookQuery,
            editingID: store.editingAnnotationID
        )
    }

    private var sections: [NotebookSection] {
        NotebookSections.build(matchingAnnotations, contents: store.contents)
    }

    private var visibleCount: Int { matchingAnnotations.count }

    private var navigableIDs: [UUID] {
        sections.filter { !collapsed.contains($0.title) }
            .flatMap { $0.annotations.map(\.id) }
    }

    private var selectedAnnotation: AnnotationRecord? {
        annotations.first { $0.id == selectedID }
    }

    private var readingMarker: (before: UUID?, atEnd: Bool) {
        guard store.notebookFilter == .all, store.notebookQuery.isEmpty,
              let locator = store.selectedBook?.lastLocator
        else { return (nil, false) }
        let ordered = sections.flatMap(\.annotations)
        guard !ordered.isEmpty,
              let index = NotebookSections.readingMarkerIndex(in: ordered, readingLocator: locator)
        else { return (nil, false) }
        return index < ordered.count ? (ordered[index].id, false) : (nil, true)
    }

    private func sectionTitle(for annotation: AnnotationRecord) -> String {
        NotebookSections.title(locator: annotation.locator, chapter: annotation.chapter, contents: store.contents)
    }

    /// Selects an entry and scrolls to it, opening its section. Waits a turn
    /// so a just-inserted entry is laid out before scrolling.
    private func reveal(_ id: UUID, proxy: ScrollViewProxy) {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return }
        selectedID = id
        collapsed.remove(sectionTitle(for: annotation))
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func moveSelection(by step: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        // Arrow keys belong to the note editor while one is open.
        guard store.editingAnnotationID == nil else { return .ignored }
        let ids = navigableIDs
        guard !ids.isEmpty else { return .ignored }
        let next: UUID
        if let selectedID, let index = ids.firstIndex(of: selectedID) {
            next = ids[min(max(index + step, 0), ids.count - 1)]
        } else {
            next = step > 0 ? ids[0] : ids[ids.count - 1]
        }
        selectedID = next
        proxy.scrollTo(next)
        return .handled
    }
}

private struct ReadingMarker: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(LeafPalette.amberMark)
                .frame(width: 6, height: 6)
            Text("You’re reading here")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(LeafPalette.amberText)
            Rectangle()
                .fill(LeafPalette.amberMark.opacity(0.35))
                .frame(height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

struct NotebookEntryRow: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Bindable var annotation: AnnotationRecord
    let isSelected: Bool
    let select: () -> Void
    let returnFocus: () -> Void
    @FocusState private var editorFocused: Bool
    @State private var isHovered = false
    /// The note as it was when editing began, restored by Esc.
    @State private var noteBeforeEditing = ""

    private var isEditing: Bool { store.editingAnnotationID == annotation.id }
    private var isPageNote: Bool { annotation.quote.isEmpty }
    private var hasNote: Bool { !annotation.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var page: Int? { AnnotationLocation.page(annotation.locator) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                select()
                store.navigate(to: annotation)
            } label: {
                if isPageNote {
                    Label(pageNoteTitle, systemImage: "note.text")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text(quote)
                        .font(.system(size: 14.5, design: .serif))
                        .lineSpacing(4)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .help(isPageNote ? "Go to Page" : "Go to Highlight")

            if isEditing {
                editor
                    .padding(.top, 4)
            } else if hasNote {
                Text(Self.markdown(annotation.note))
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(.primary.opacity(0.9))
                    .textSelection(.disabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        select()
                        store.beginEditingNote(annotation)
                    }
                    .help("Edit Note")
                    .padding(.top, 4)
            }

            if !isEditing {
                controls
            }
        }
        .padding(.top, 9)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.bottom, 4)
        .background(background, in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu { actions }
        .onChange(of: editorFocused) { _, focused in
            if !focused, isEditing { store.finishEditingNote(annotation, context: modelContext) }
        }
        .accessibilityElement(children: .contain)
    }

    private var quote: AttributedString {
        // PDF selections keep the page's line breaks; show the passage as prose.
        let flowing = annotation.quote
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        var text = AttributedString(flowing)
        text.backgroundColor = annotation.color.wash
        return text
    }

    private var background: Color {
        return isSelected || isEditing ? Color.primary.opacity(0.05) : .clear
    }

    private var pageNoteTitle: String {
        page.map { "Note on page \($0)" } ?? "Note on this page"
    }

    // MARK: Editing

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                // Sizes the editor to its text so the note grows in place.
                Text(annotation.note.isEmpty ? " " : annotation.note + " ")
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                TextEditor(text: $annotation.note)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .focused($editorFocused)
                    .padding(.leading, -5)
                    .accessibilityLabel("Note")
                    // Return saves; Shift-Return falls through to a new line.
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        finishEditing()
                        return .handled
                    }
                if annotation.note.isEmpty {
                    Text(isPageNote ? "Write about this page…" : "What does this make you think?")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 20)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(LeafPalette.amberMark.opacity(0.6), lineWidth: 1)
            )

            Text("Return to save · Shift-Return for a new line · Esc to cancel")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .padding(.bottom, 6)
        }
        .onAppear {
            noteBeforeEditing = annotation.note
            editorFocused = true
        }
        .onExitCommand { cancelEditing() }
    }

    private func finishEditing() {
        store.finishEditingNote(annotation, context: modelContext)
        returnFocus()
    }

    /// Restores the note as it was; a new, still-empty note is discarded.
    private func cancelEditing() {
        annotation.note = noteBeforeEditing
        finishEditing()
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 2) {
            if !hasNote, !isEditing, !isPageNote {
                Button {
                    select()
                    store.beginEditingNote(annotation)
                } label: {
                    Label("Add note", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LeafPalette.amberText)
                .padding(.trailing, 8)
            }
            Group {
                if let page, !isPageNote {
                    Text("p. \(page) · \(annotation.createdAt, format: .relative(presentation: .named))")
                } else {
                    Text(annotation.createdAt, format: .relative(presentation: .named))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer(minLength: 4)

            if !isPageNote, let book = store.selectedBook {
                Button {
                    store.copyQuoteWithCitation(annotation, in: book)
                } label: {
                    Image(systemName: "quote.opening")
                        .font(.caption)
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Copy Quote with Citation")
                .accessibilityLabel("Copy quote with citation")
            }
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .frame(width: 22, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More actions")
        }
        .foregroundStyle(.secondary)
        .frame(height: 22)
        .opacity(isHovered || isSelected ? 1 : 0)
    }

    @ViewBuilder
    private var actions: some View {
        Button(hasNote ? "Edit Note" : "Add Note") {
            select()
            store.beginEditingNote(annotation)
        }
        Button("Go to \(isPageNote ? "Page" : "Highlight")") {
            select()
            store.navigate(to: annotation)
        }
        if !isPageNote, let book = store.selectedBook {
            Button("Copy Quote with Citation") {
                store.copyQuoteWithCitation(annotation, in: book)
            }
        }
        Divider()
        Button(isPageNote ? "Delete Note" : "Delete Highlight", role: .destructive) {
            store.deleteHighlight(annotation, context: modelContext)
        }
    }

    static func markdown(_ note: String) -> AttributedString {
        (try? AttributedString(
            markdown: note,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(note)
    }
}
