import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension ReaderStore {
    /// Resolves a book's citation: cached Crossref metadata, then a DOI set by
    /// the reader or found on the document's first pages, then the library
    /// title and author.
    func citation(for book: BookRecord) async -> CitationMetadata {
        if let cached = book.citation { return cached }
        let fallback = CitationMetadata.fallback(title: book.title, author: book.author, format: book.format)
        let manualDOI = book.doi
        guard !manualDOI.isEmpty || !settledCitationLookups.contains(book.id) else { return fallback }

        let format = book.format
        let url = book.fileURL
        let loadedText = selectedBook?.id == book.id ? extractedResearchText : nil
        let (candidateText, detected) = manualDOI.isEmpty
            ? await Task.detached(priority: .userInitiated) { () -> (String, [String]) in
                var text = loadedText
                if text == nil, format != .pdf {
                    switch try? ContentLoader.load(format: format, fileURL: url) {
                    case .attributedText(let value), .epub(let value, _): text = value.string
                    default: break
                    }
                }
                let candidate = DOIDetector.candidateText(format: format, url: url, text: text)
                return (candidate, DOIDetector.all(in: candidate))
            }.value
            : ("", [manualDOI])

        let client = CrossrefMetadataClient()
        for doi in detected.prefix(3) {
            do {
                guard let metadata = try await client.metadata(doi: doi) else { continue }
                // A detected DOI must belong to this work, not to a reference it cites.
                if manualDOI.isEmpty,
                   !DOIDetector.titleAppears(metadata.title, in: candidateText),
                   !PaperSearch.titleMatches(metadata.title, book.title) {
                    continue
                }
                book.doi = metadata.doi ?? doi
                book.citation = metadata
                return metadata
            } catch {
                // Offline or Crossref unavailable: try again next time.
                return fallback
            }
        }
        settledCitationLookups.insert(book.id)
        return fallback
    }

    func promptForDOI(for book: BookRecord) {
        doiPromptText = book.doi
        doiPromptBook = book
    }

    func copyBibTeX(for book: BookRecord) {
        Task {
            let citation = await citation(for: book)
            copyToPasteboard(CitationFormatter.bibTeX(citation))
            showToast(citation.doi == nil ? "BibTeX copied (no DOI found)" : "BibTeX copied")
        }
    }

    func copyAPAReference(for book: BookRecord) {
        Task {
            let citation = await citation(for: book)
            copyToPasteboard(CitationFormatter.apa(citation))
            showToast(citation.doi == nil ? "Reference copied (no DOI found)" : "Reference copied")
        }
    }

    func copyQuoteWithCitation(_ annotation: AnnotationRecord, in book: BookRecord) {
        let highlight = ExportedHighlight(annotation)
        Task {
            let citation = await citation(for: book)
            copyToPasteboard(CitationFormatter.quote(highlight.quote, citation: citation, page: highlight.page))
            showToast("Quote copied with citation")
        }
    }

    /// Sets or clears a reader-supplied DOI and refreshes the cached citation.
    func setDOI(_ value: String, for book: BookRecord) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        book.citation = nil
        settledCitationLookups.remove(book.id)
        guard !trimmed.isEmpty else {
            book.doi = ""
            showToast("DOI cleared")
            return
        }
        guard let doi = DOIDetector.all(in: trimmed).first ?? PaperSearch.normalizedDOI(trimmed) else {
            showToast("That doesn’t look like a DOI")
            return
        }
        book.doi = doi
        Task {
            let citation = await citation(for: book)
            if citation.doi == nil {
                book.doi = ""
                showToast("Crossref couldn’t find that DOI")
            } else {
                showToast("Citation found: \(CitationFormatter.inText(citation))")
            }
        }
    }

    func exportNotes(for book: BookRecord, context: ModelContext) {
        let panel = NSSavePanel()
        panel.title = "Export Notes"
        panel.nameFieldStringValue = NotesMarkdown.fileName(for: book.title)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let highlights = Self.highlights(for: book.id, context: context)
        Task {
            let citation = await citation(for: book)
            do {
                try NotesMarkdown.document(citation: citation, highlights: highlights)
                    .write(to: url, atomically: true, encoding: .utf8)
                showToast("Exported \(highlights.count) \(highlights.count == 1 ? "highlight" : "highlights")")
            } catch {
                showToast("Couldn’t export notes")
            }
        }
    }

    /// Writes one Markdown file per book with highlights, plus a shared
    /// BibTeX file for the whole library, into a folder the reader picks.
    func exportLibraryNotes(books: [BookRecord], context: ModelContext) {
        let panel = NSOpenPanel()
        panel.title = "Export Library Notes"
        panel.prompt = "Export"
        panel.message = "Leaf writes a Markdown file per book and a Leaf Library.bib file."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        showToast("Exporting notes…")
        Task {
            var bibliography: [String] = []
            var usedNames: Set<String> = []
            var exported = 0
            do {
                for book in books {
                    let citation = await citation(for: book)
                    bibliography.append(CitationFormatter.bibTeX(citation))
                    let highlights = Self.highlights(for: book.id, context: context)
                    guard !highlights.isEmpty else { continue }
                    var name = NotesMarkdown.fileName(for: book.title)
                    if usedNames.contains(name) {
                        name = NotesMarkdown.fileName(for: "\(book.title) \(CitationFormatter.citeKey(citation))")
                    }
                    usedNames.insert(name)
                    try NotesMarkdown.document(citation: citation, highlights: highlights)
                        .write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
                    exported += 1
                }
                try (bibliography.joined(separator: "\n\n") + "\n")
                    .write(to: folder.appendingPathComponent("Leaf Library.bib"), atomically: true, encoding: .utf8)
                showToast("Exported notes for \(exported) \(exported == 1 ? "book" : "books")")
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch {
                showToast("Couldn’t export notes")
            }
        }
    }

    private static func highlights(for bookID: UUID, context: ModelContext) -> [ExportedHighlight] {
        let descriptor = FetchDescriptor<AnnotationRecord>(predicate: #Predicate { $0.bookID == bookID })
        return ((try? context.fetch(descriptor)) ?? []).map(ExportedHighlight.init)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension ExportedHighlight {
    init(_ annotation: AnnotationRecord) {
        self.init(
            quote: annotation.quote, note: annotation.note, color: annotation.color,
            locator: annotation.locator, chapter: annotation.chapter, createdAt: annotation.createdAt
        )
    }
}

/// Export and citation actions for a book, shared by the reader toolbar and
/// the library context menu.
struct CiteMenuItems: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    let book: BookRecord

    var body: some View {
        Button {
            store.exportNotes(for: book, context: modelContext)
        } label: {
            Label("Export Notes as Markdown…", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button {
            store.copyAPAReference(for: book)
        } label: {
            Label("Copy APA Reference", systemImage: "text.quote")
        }
        Button {
            store.copyBibTeX(for: book)
        } label: {
            Label("Copy BibTeX", systemImage: "curlybraces")
        }
        Divider()
        Button {
            store.promptForDOI(for: book)
        } label: {
            Label(book.doi.isEmpty ? "Set DOI…" : "Edit DOI (\(book.doi))…", systemImage: "number")
        }
    }
}
