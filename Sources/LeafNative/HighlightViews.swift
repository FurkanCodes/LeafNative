import SwiftUI

struct AllHighlightsView: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    let annotations: [AnnotationRecord]
    let books: [BookRecord]

    var body: some View {
        List {
            ForEach(annotations) { annotation in
                Button {
                    if let book = books.first(where: { $0.id == annotation.bookID }) {
                        store.navigate(to: annotation, in: book)
                        store.inspectorVisible = true
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Circle()
                                .fill(annotation.color.swiftUIColor)
                                .frame(width: 7, height: 7)
                            Text(bookTitle(for: annotation))
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(annotation.createdAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if !annotation.quote.isEmpty {
                            Text(annotation.quote)
                                .font(.system(.body, design: .serif))
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                        }
                        if !annotation.note.isEmpty {
                            Text(annotation.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !annotation.quote.isEmpty,
                       let book = books.first(where: { $0.id == annotation.bookID }) {
                        Button("Copy Quote with Citation") {
                            store.copyQuoteWithCitation(annotation, in: book)
                        }
                    }
                }
            }
        }
        .navigationTitle("Highlights & Notes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.exportLibraryNotes(books: books, context: modelContext)
                } label: {
                    Label("Export All Notes", systemImage: "square.and.arrow.up")
                }
                .help("Export every book’s notes as Markdown, with a BibTeX library")
                .disabled(annotations.isEmpty)
            }
        }
        .overlay {
            if annotations.isEmpty {
                ContentUnavailableView(
                    "No Highlights",
                    systemImage: "highlighter",
                    description: Text("Select text while reading to save it here.")
                )
            }
        }
    }

    private func bookTitle(for annotation: AnnotationRecord) -> String {
        books.first(where: { $0.id == annotation.bookID })?.title ?? "Book"
    }
}
