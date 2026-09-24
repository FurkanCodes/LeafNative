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

// MARK: - Notebook

struct NotebookInspector: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    let annotations: [AnnotationRecord]

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Show", selection: $store.inspectorTab) {
                Text("All").tag(0)
                Text("Notes (\(noteCount))").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                List {
                    if visibleAnnotations.isEmpty {
                        emptyState
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(visibleAnnotations) { annotation in
                            NotebookEntryRow(annotation: annotation)
                                .id(annotation.id)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onChange(of: store.editingAnnotationID) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.bar)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Notebook")
                    .font(.headline)
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.addPageNote(context: modelContext)
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("New Note on This Page (⇧⌘N with no selection)")
            .disabled(store.selectedBook == nil)

            if let book = store.selectedBook {
                Menu {
                    CiteMenuItems(book: book)
                } label: {
                    Label("Export & Cite", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Export notes or copy a citation")
            }
            Button {
                store.inspectorVisible = false
            } label: {
                Label("Hide Notebook", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Hide Notebook")
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                store.inspectorTab == 0 ? "Nothing here yet" : "No notes yet",
                systemImage: store.inspectorTab == 0 ? "highlighter" : "note.text"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                hint("Select text, then press ⇧⌘H to highlight or ⇧⌘N to add a note.")
                hint("Right-click a highlight in the book to add or edit its note.")
                hint("Click \(Image(systemName: "square.and.pencil")) to write a note about the current page.")
            }
        }
        .padding(.vertical, 14)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: String {
        let highlights = annotations.lazy.filter { !$0.quote.isEmpty }.count
        let parts = [
            "\(highlights) \(highlights == 1 ? "highlight" : "highlights")",
            "\(noteCount) \(noteCount == 1 ? "note" : "notes")",
        ]
        return parts.joined(separator: " · ")
    }

    private var visibleAnnotations: [AnnotationRecord] {
        let ordered = AnnotationLocation.sortedForReading(annotations)
        guard store.inspectorTab == 1 else { return ordered }
        // Keep the entry being written visible even before it has text.
        return ordered.filter { !$0.note.isEmpty || $0.id == store.editingAnnotationID }
    }

    private var noteCount: Int {
        annotations.lazy.filter { !$0.note.isEmpty }.count
    }
}

struct NotebookEntryRow: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Bindable var annotation: AnnotationRecord
    @FocusState private var editorFocused: Bool

    private var isEditing: Bool { store.editingAnnotationID == annotation.id }
    private var isPageNote: Bool { annotation.quote.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                store.navigate(to: annotation)
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    metadata
                    if !isPageNote {
                        Text(annotation.quote)
                            .font(.system(.callout, design: .serif))
                            .lineSpacing(3)
                            .padding(.leading, 9)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(annotation.color.swiftUIColor)
                                    .frame(width: 3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to \(isPageNote ? "Note" : "Highlight")")

            if isEditing {
                editor
            } else if !annotation.note.isEmpty {
                Text(annotation.note)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { store.beginEditingNote(annotation) }
                    .help("Edit Note")
            } else {
                Button {
                    store.beginEditingNote(annotation)
                } label: {
                    Label("Add note", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contextMenu { actions }
        .onChange(of: editorFocused) { _, focused in
            if !focused, isEditing { store.finishEditingNote(annotation, context: modelContext) }
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if isPageNote {
                Image(systemName: "note.text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(annotation.color.swiftUIColor)
                    .frame(width: 7, height: 7)
            }
            Text(locationLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(annotation.createdAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .frame(width: 18, height: 14)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $annotation.note)
                .font(.callout)
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 70, maxHeight: 220)
                .padding(6)
                .overlay(alignment: .topLeading) {
                    if annotation.note.isEmpty {
                        Text(isPageNote ? "Write about this page…" : "What does this make you think?")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
            HStack {
                Text("Saved automatically")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") {
                    store.finishEditingNote(annotation, context: modelContext)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .controlSize(.small)
            }
        }
        .onAppear { editorFocused = true }
        .onExitCommand { store.finishEditingNote(annotation, context: modelContext) }
    }

    @ViewBuilder
    private var actions: some View {
        Button(annotation.note.isEmpty ? "Add Note" : "Edit Note") {
            store.beginEditingNote(annotation)
        }
        Button("Go to \(isPageNote ? "Page" : "Highlight")") {
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

    private var locationLabel: String {
        let chapter = annotation.chapter.trimmingCharacters(in: .whitespaces)
        let hasChapter = !NotesMarkdown.placeholderChapters.contains(chapter)
        if let page = AnnotationLocation.page(annotation.locator) {
            // PDF chapters are stored as "Section · Page 3 of 20"; keep only the section.
            let section = chapter.components(separatedBy: " · Page ").first ?? ""
            let showsSection = hasChapter && !section.hasPrefix("Page ")
            return showsSection ? "p. \(page) · \(section)" : "p. \(page)"
        }
        return hasChapter ? chapter : "This book"
    }
}
