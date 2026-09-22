import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookRecord.lastOpened, order: .reverse)
    private var books: [BookRecord]
    @Query(sort: \AnnotationRecord.createdAt, order: .reverse)
    private var annotations: [AnnotationRecord]

    var body: some View {
        @Bindable var store = store

        NavigationSplitView(columnVisibility: $store.columnVisibility) {
            SidebarView(
                books: books,
                annotationCount: annotations.count
            )
            .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        } detail: {
            destinationView
        }
        .inspector(isPresented: $store.inspectorVisible) {
            NotebookInspector(
                annotations: selectedBookAnnotations
            )
            .inspectorColumnWidth(min: 270, ideal: 304, max: 380)
        }
        .fileImporter(
            isPresented: $store.importerVisible,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            importSelection(result)
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(message: toast)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: store.toast)
        .task {
            seedIfNeeded()
            store.checkForUpdates(userInitiated: false)
        }
        .onOpenURL { url in
            importURL(url)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .leafCheckUpdates)
        ) { _ in
            store.checkForUpdates(userInitiated: true)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .leafOpenBook)
        ) { _ in
            store.importerVisible = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .leafHighlight)
        ) { notification in
            let color = notification.object as? HighlightColor ?? .amber
            store.addHighlight(color: color, context: modelContext)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .leafAddNote)
        ) { _ in
            store.addNote(context: modelContext)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .leafPreviousPage)
        ) { _ in
            store.previousPage()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .leafNextPage)
        ) { _ in
            store.nextPage()
        }
        .alert(
            "Update Available",
            isPresented: $store.updateAlertVisible
        ) {
            Button("Download & Install") {
                store.installAvailableUpdate()
            }
            if let url = store.availableUpdate?.htmlURL {
                Button("View Release") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Later", role: .cancel) {}
        } message: {
            if let release = store.availableUpdate {
                Text(
                    "Leaf Native \(release.version) is ready — "
                        + "you're on \(UpdateChecker.currentVersion)."
                )
            }
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch store.destination {
        case .library:
            LibraryScreen(books: books)
        case .reader:
            if let book = store.selectedBook ?? books.first {
                ReaderScreen(
                    book: book,
                    annotations: annotations.filter { $0.bookID == book.id }
                )
                .onAppear {
                    if store.selectedBook == nil {
                        store.selectedBook = book
                    }
                }
            } else {
                EmptyLibraryView()
            }
        case .highlights:
            AllHighlightsView(annotations: annotations, books: books)
        case .favorites:
            LibraryScreen(books: books.filter(\.isFavorite))
        }
    }

    private var selectedBookAnnotations: [AnnotationRecord] {
        guard let id = store.selectedBook?.id ?? books.first?.id else {
            return []
        }
        return annotations.filter { $0.bookID == id }
    }

    private func importSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            importURL(url)
        } catch {
            store.showToast(error.localizedDescription)
        }
    }

    private func importURL(_ url: URL) {
        do {
            let imported = try ImportService.importBook(from: url)
            if !imported.contentHash.isEmpty,
               let existing = books.first(where: {
                   $0.contentHash == imported.contentHash
               }) {
                try? FileManager.default.removeItem(at: imported.localURL)
                store.select(existing)
                store.showToast("\(existing.title) is already in your Library")
                return
            }
            let tones: [CoverTone] = [.ochre, .forest, .clay, .ink, .linen]
            let book = BookRecord(
                title: imported.title,
                author: imported.author,
                format: imported.format,
                filePath: imported.localURL.path,
                currentChapter: imported.chapter,
                contentHash: imported.contentHash,
                coverTone: tones[books.count % tones.count]
            )
            modelContext.insert(book)
            store.select(book)
            store.showToast("\(imported.format.displayName) added to Library")
        } catch {
            store.showToast(error.localizedDescription)
        }
    }

    private func seedIfNeeded() {
        guard books.isEmpty else {
            if store.selectedBook == nil {
                store.selectedBook = books.first
            }
            return
        }

        let sampleID = UUID(uuidString: "A66AABAF-9F1A-4A6A-93F5-1A2D3C4B5E6F")!
        let sample = BookRecord(
            id: sampleID,
            title: "The Shape of Attention",
            author: "Eva Arden",
            format: .sample,
            progress: 0.38,
            currentChapter: "4. A Practice of Noticing",
            coverTone: .ochre
        )
        modelContext.insert(sample)
        modelContext.insert(
            AnnotationRecord(
                bookID: sampleID,
                quote: "Some lines need to remain open for a while. They gather meaning from what follows.",
                note: "A reminder to postpone summarizing until the end of a section.",
                color: .amber,
                locator: "text:493:83",
                chapter: "A Practice of Noticing",
                createdAt: .now.addingTimeInterval(-480)
            )
        )
        modelContext.insert(
            AnnotationRecord(
                bookID: sampleID,
                quote: "The strongest notes are not summaries of what the author has said. They are records of contact.",
                color: .sage,
                locator: "text:1263:102",
                chapter: "A Practice of Noticing",
                createdAt: .now.addingTimeInterval(-120)
            )
        )
        store.selectedBook = sample
    }
}
