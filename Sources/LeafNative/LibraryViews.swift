import SwiftUI

struct SidebarView: View {
    @Environment(ReaderStore.self) private var store
    let books: [BookRecord]
    let annotationCount: Int

    var body: some View {
        List {
            Section {
                sidebarRow(
                    .library,
                    title: "Library",
                    symbol: "books.vertical"
                )
                sidebarRow(
                    .reader,
                    title: "Now Reading",
                    symbol: "book"
                )
                Button {
                    store.destination = .reader
                    store.openAICompanion()
                } label: {
                    Label("AI Companion", systemImage: "sparkles")
                }
                .buttonStyle(.plain)
                sidebarRow(
                    .highlights,
                    title: "Highlights",
                    symbol: "highlighter",
                    count: annotationCount
                )
                sidebarRow(
                    .favorites,
                    title: "Favorites",
                    symbol: "heart"
                )
            }

            if let book = store.selectedBook ?? books.first {
                Section("Current Book") {
                    Button {
                        store.select(book)
                    } label: {
                        HStack(spacing: 10) {
                            BookCoverView(book: book, size: .mini)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(book.author)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }

                Section("Contents") {
                    if store.contents.isEmpty {
                        Text("No document outline")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(store.contents) { entry in
                            Button {
                                store.navigate(to: entry)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(entry.title)
                                        .font(.caption)
                                        .lineLimit(2)
                                    Spacer(minLength: 0)
                                    if let pageIndex = entry.pdfPageIndex {
                                        Text(pageIndex + 1, format: .number)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.leading, CGFloat(min(entry.level, 3)) * 10)
                                .foregroundStyle(
                                    store.activeContentEntryID == entry.id
                                        ? .primary
                                        : .secondary
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                store.activeContentEntryID == entry.id
                                    ? LeafPalette.amber.opacity(0.10)
                                    : Color.clear
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    store.importerVisible = true
                } label: {
                    Label("Import a Book", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("o")
            }
            .background(.bar)
        }
        .navigationTitle("Leaf")
    }

    @ViewBuilder
    private func sidebarRow(
        _ destination: SidebarDestination,
        title: String,
        symbol: String,
        count: Int? = nil
    ) -> some View {
        Button {
            store.destination = destination
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let count {
                    Text(count, format: .number)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            store.destination == destination
                ? Color.primary.opacity(0.08)
                : Color.clear
        )
    }

}

struct LibraryScreen: View {
    @Environment(ReaderStore.self) private var store
    let books: [BookRecord]

    private let columns = [
        GridItem(.adaptive(minimum: 145, maximum: 190), spacing: 30)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                libraryHeader

                if let current = books.first {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Continue Reading")
                            .font(.headline)

                        Button {
                            store.select(current)
                        } label: {
                            ContinueReadingView(book: current)
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("All Books")
                            .font(.headline)
                        Spacer()
                        Menu {
                            ForEach(ReaderStore.LibrarySort.allCases) { sort in
                                Button {
                                    store.librarySort = sort
                                } label: {
                                    if store.librarySort == sort {
                                        Label(sort.label, systemImage: "checkmark")
                                    } else {
                                        Text(sort.label)
                                    }
                                }
                            }
                        } label: {
                            Label(
                                store.librarySort.label,
                                systemImage: "arrow.up.arrow.down"
                            )
                            .font(.caption)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    if books.isEmpty {
                        EmptyLibraryView()
                            .frame(maxWidth: .infinity)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                            ForEach(sortedBooks) { book in
                                Button {
                                    store.select(book)
                                } label: {
                                    LibraryBookView(book: book)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(book.isFavorite ? "Remove Favorite" : "Favorite") {
                                        book.isFavorite.toggle()
                                    }
                                    Button("Open") {
                                        store.select(book)
                                    }
                                    Divider()
                                    CiteMenuItems(book: book)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 42)
            .padding(.top, 34)
            .padding(.bottom, 70)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(LeafPalette.paper)
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.importerVisible = true
                } label: {
                    Label("Add Book", systemImage: "plus")
                }
            }
        }
    }

    private var sortedBooks: [BookRecord] {
        switch store.librarySort {
        case .lastOpened:
            books
        case .title:
            books.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title)
                    == .orderedAscending
            }
        case .author:
            books.sorted {
                switch $0.author.localizedCaseInsensitiveCompare($1.author) {
                case .orderedSame:
                    $0.title.localizedCaseInsensitiveCompare($1.title)
                        == .orderedAscending
                case .orderedAscending:
                    true
                case .orderedDescending:
                    false
                }
            }
        }
    }

    private var libraryHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Library")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.7)
                Text("\(books.count) \(books.count == 1 ? "book" : "books") · stored on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct ContinueReadingView: View {
    let book: BookRecord

    var body: some View {
        HStack(spacing: 30) {
            BookCoverView(book: book, size: .large)

            VStack(alignment: .leading, spacing: 0) {
                Text(book.format.displayName)
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(LeafPalette.amber)

                Text(book.title)
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .tracking(-0.7)
                    .padding(.top, 8)

                Text(book.author)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)

                Label(book.currentChapter, systemImage: "book.pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)

                ProgressView(value: book.progress)
                    .tint(LeafPalette.amber)
                    .frame(maxWidth: 430)
                    .padding(.top, 12)

                Text("Resume Reading")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 12)
            }
            Spacer(minLength: 20)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 218, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.5), lineWidth: 0.5)
        }
        .contentShape(Rectangle())
    }
}

struct LibraryBookView: View {
    let book: BookRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BookCoverView(book: book, size: .shelf)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(book.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Label {
                    Text(book.lastOpened, style: .relative)
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct BookCoverView: View {
    enum Size {
        case mini
        case shelf
        case large

        var width: CGFloat {
            switch self {
            case .mini: 34
            case .shelf: 140
            case .large: 132
            }
        }

        var height: CGFloat {
            switch self {
            case .mini: 48
            case .shelf: 196
            case .large: 188
            }
        }
    }

    let book: BookRecord
    let size: Size

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: size == .mini ? 3 : 6)
                .fill(coverColor)
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(width: 1)
                .padding(.leading, size == .mini ? 6 : 10)

            if size == .mini {
                Text(book.title)
                    .font(.system(size: 6, weight: .medium, design: .serif))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(3)
                    .padding(.horizontal, 8)
            } else {
                VStack(alignment: .leading) {
                    Rectangle()
                        .fill(.white.opacity(0.55))
                        .frame(width: 26, height: 2)
                    Spacer()
                    Image(systemName: book.format.symbolName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(book.title)
                        .font(.system(size: size == .large ? 16 : 15, weight: .medium, design: .serif))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                    Text(book.author.uppercased())
                        .font(.system(size: 7, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
                .padding(size == .large ? 16 : 15)
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(size == .mini ? 0.08 : 0.14), radius: size == .mini ? 2 : 5, y: size == .mini ? 1 : 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.title), \(book.author)")
    }

    private var coverColor: Color {
        switch book.coverTone {
        case .ochre: Color(red: 0.66, green: 0.43, blue: 0.11)
        case .forest: Color(red: 0.28, green: 0.36, blue: 0.28)
        case .clay: Color(red: 0.58, green: 0.35, blue: 0.30)
        case .ink: Color(red: 0.20, green: 0.22, blue: 0.23)
        case .linen: Color(red: 0.52, green: 0.49, blue: 0.43)
        }
    }
}

struct EmptyLibraryView: View {
    @Environment(ReaderStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("Your Library Is Empty", systemImage: "books.vertical")
        } description: {
            Text("Add a book to begin reading and studying.")
        } actions: {
            Button("Add Book…") {
                store.importerVisible = true
            }
        }
    }
}
