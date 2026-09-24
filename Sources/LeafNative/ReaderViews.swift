import AppKit
import SwiftData
import SwiftUI

struct ReaderScreen: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    let book: BookRecord
    let annotations: [AnnotationRecord]

    var body: some View {
        @Bindable var store = store

        ZStack {
            store.readerTheme.background
                .ignoresSafeArea()

            Group {
                if store.isLoading {
                    ProgressView("Opening \(book.title)…")
                        .controlSize(.small)
                } else if let error = store.loadingError {
                    ContentUnavailableView {
                        Label("Unable to Open Book", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") {
                            loadBook()
                        }
                    }
                } else if let content = store.loadedContent {
                    contentView(content)
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle(book.title)
        .navigationSubtitle(book.currentChapter)
        .searchable(
            text: $store.searchText,
            placement: .toolbar,
            prompt: "Search book"
        )
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    store.previousPage()
                } label: {
                    Label("Previous Page", systemImage: "chevron.left")
                }
                .help("Previous Page (←)")

                Button {
                    store.nextPage()
                } label: {
                    Label("Next Page", systemImage: "chevron.right")
                }
                .help("Next Page (→)")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(HighlightColor.allCases, id: \.self) { color in
                        Button {
                            store.addHighlight(color: color, context: modelContext)
                        } label: {
                            Label(color.displayName, systemImage: "circle.fill")
                        }
                    }
                    Divider()
                    Button {
                        store.addNote(context: modelContext)
                    } label: {
                        Label("Highlight with Note", systemImage: "note.text.badge.plus")
                    }
                } label: {
                    Label("Highlight", systemImage: "highlighter")
                }
                .help("Highlight Selection (⇧⌘H)")

                Menu {
                    Button {
                        store.toggleBookmark(on: book)
                    } label: {
                        Label(
                            book.isBookmarked ? "Remove Bookmark" : "Bookmark Page",
                            systemImage: book.isBookmarked
                                ? "bookmark.slash" : "bookmark"
                        )
                    }

                    Button {
                        store.navigateToBookmark(in: book)
                    } label: {
                        Label("Go to Bookmark", systemImage: "bookmark.circle")
                    }
                    .disabled(
                        !book.isBookmarked || book.bookmarkLocator.isEmpty
                    )
                } label: {
                    Label(
                        "Bookmark",
                        systemImage: book.isBookmarked ? "bookmark.fill" : "bookmark"
                    )
                }

                Menu {
                    CiteMenuItems(book: book)
                } label: {
                    Label("Export & Cite", systemImage: "square.and.arrow.up")
                }
                .help("Export notes or copy a citation")

                Button {
                    store.openAICompanion()
                } label: {
                    Label("Ask AI", systemImage: "sparkles")
                }
                .help("Ask AI about this book")

                Button {
                    store.appearanceVisible.toggle()
                } label: {
                    Label("Reading Appearance", systemImage: "textformat.size")
                }
                .popover(isPresented: $store.appearanceVisible, arrowEdge: .top) {
                    ReadingAppearanceView()
                        .environment(store)
                }

                Button {
                    if store.inspectorVisible && store.companionPane == .notebook {
                        store.inspectorVisible = false
                    } else {
                        store.companionPane = .notebook
                        store.inspectorVisible = true
                    }
                } label: {
                    Label(
                        store.inspectorVisible ? "Hide Notebook" : "Show Notebook",
                        systemImage: "sidebar.right"
                    )
                }
                .help(store.inspectorVisible ? "Hide Notebook" : "Show Notebook")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            readerFooter
        }
        .task(id: book.id) {
            loadBook()
        }
    }

    @ViewBuilder
    private func contentView(_ content: LoadedBookContent) -> some View {
        switch content {
        case .attributedText(let text):
            NativeTextReader(
                content: text,
                annotations: annotations,
                book: book
            )
        case .epub(let text, _):
            NativeTextReader(
                content: text,
                annotations: annotations,
                book: book
            )
        case .pdf(let url):
            PDFReaderView(url: url, book: book)
        case .comic(let imageData):
            ComicReaderView(images: imageData)
        case .quickLook(let url):
            QuickLookReaderView(url: url)
        case .unavailable(let message):
            ContentUnavailableView(
                "Format Not Available",
                systemImage: "doc.questionmark",
                description: Text(message)
            )
        }
    }

    private var readerFooter: some View {
        HStack(spacing: 12) {
            Label(
                book.format == .sample ? "Chapter 4 of 8" : book.format.displayName,
                systemImage: "list.bullet.indent"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            ProgressView(value: book.progress)
                .tint(LeafPalette.amber)

            Text(book.progress, format: .percent.precision(.fractionLength(0)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    @MainActor
    private func loadBook() {
        store.isLoading = true
        store.loadingError = nil
        store.loadedContent = nil
        store.researchContentHash = ""
        let format = book.format
        let fileURL = book.fileURL
        Task {
            do {
                let (content, currentHash) = try await Task.detached(priority: .userInitiated) {
                    let content = try ContentLoader.load(format: format, fileURL: fileURL)
                    let text: String?
                    switch content {
                    case .attributedText(let value), .epub(let value, _):
                        text = value.string
                    default:
                        text = nil
                    }
                    let hash = ResearchContentHash.value(format: format, url: fileURL, text: text)
                    return (content, hash)
                }.value
                if let currentHash, currentHash != store.researchContentHash {
                    store.researchContentHash = currentHash
                    await ResearchIndex.shared.clear(bookID: book.id)
                }
                if let currentHash {
                    let text: String? = switch content {
                    case .attributedText(let value), .epub(let value, _): value.string
                    default: nil
                    }
                    let bookID = book.id
                    Task.detached(priority: .utility) {
                        await ResearchIndex.shared.prepare(
                            bookID: bookID, contentHash: currentHash, format: format,
                            url: fileURL, extractedText: text
                        )
                    }
                }
                store.loadedContent = content
                if case .epub(_, let entries) = content {
                    store.setContents(entries)
                } else {
                    let toc = try await Task.detached(priority: .utility) {
                        try ContentLoader.tableOfContents(
                            format: format,
                            fileURL: fileURL
                        )
                    }.value
                    store.setContents(toc)
                }
                store.isLoading = false
            } catch {
                store.loadingError = error.localizedDescription
                store.isLoading = false
            }
        }
    }
}

struct ReadingAppearanceView: View {
    @Environment(ReaderStore.self) private var store

    var body: some View {
        @Bindable var store = store

        VStack(alignment: .leading, spacing: 0) {
            Text("Reading Appearance")
                .font(.headline)
                .padding(.bottom, 14)

            HStack {
                Text("Theme")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 8) {
                    ForEach(ReaderStore.ReaderTheme.allCases) { theme in
                        Button {
                            store.readerTheme = theme
                        } label: {
                            Circle()
                                .fill(theme.background)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    Circle()
                                        .stroke(.separator, lineWidth: 1)
                                }
                                .overlay {
                                    if store.readerTheme == theme {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.bold())
                                            .foregroundStyle(theme.foreground)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(theme.label)
                    }
                }
            }
            .padding(.vertical, 11)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Text Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("A").font(.caption)
                    Slider(value: $store.fontSize, in: 14...28, step: 1)
                    Text("A").font(.title3)
                }
            }
            .padding(.vertical, 11)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Line Spacing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $store.lineSpacing, in: 2...18, step: 1)
            }
            .padding(.vertical, 11)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Page Width")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Page Width", selection: $store.pageWidth) {
                    Text("Narrow").tag(CGFloat(560))
                    Text("Medium").tag(CGFloat(680))
                    Text("Wide").tag(CGFloat(800))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.top, 11)
        }
        .padding(16)
        .frame(width: 300)
    }
}

struct NotebookInspector: View {
    @Environment(ReaderStore.self) private var store
    let annotations: [AnnotationRecord]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notebook")
                        .font(.headline)
                    Text("\(annotations.count) \(annotations.count == 1 ? "mark" : "marks") in this book")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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

            Divider()

            List {
                Section {
                    notebookTabRow(
                        tab: 0,
                        title: "Highlights",
                        symbol: "highlighter",
                        count: annotations.count
                    )
                    notebookTabRow(
                        tab: 1,
                        title: "Notes",
                        symbol: "note.text",
                        count: noteCount
                    )
                }

                Section("In This Book") {
                    if filteredAnnotations.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(
                                store.inspectorTab == 0 ? "No Highlights" : "No Notes",
                                systemImage: store.inspectorTab == 0
                                    ? "highlighter"
                                    : "note.text"
                            )
                            .font(.caption.weight(.semibold))

                            Text("Select text in the reader to begin.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredAnnotations) { annotation in
                            AnnotationInspectorRow(annotation: annotation)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.bar)
    }

    @ViewBuilder
    private func notebookTabRow(
        tab: Int,
        title: String,
        symbol: String,
        count: Int
    ) -> some View {
        Button {
            store.inspectorTab = tab
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(count, format: .number)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            store.inspectorTab == tab
                ? Color.primary.opacity(0.08)
                : Color.clear
        )
    }

    private var filteredAnnotations: [AnnotationRecord] {
        store.inspectorTab == 0
            ? annotations
            : annotations.filter { !$0.note.isEmpty }
    }

    private var noteCount: Int {
        annotations.lazy.filter { !$0.note.isEmpty }.count
    }
}

struct AnnotationInspectorRow: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Bindable var annotation: AnnotationRecord
    @State private var isEditingNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                store.navigate(to: annotation)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle()
                            .fill(annotation.color.swiftUIColor)
                            .frame(width: 7, height: 7)
                        Text(annotation.chapter)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(annotation.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Text(annotation.quote)
                        .font(.system(.callout, design: .serif))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !isEditingNote, !annotation.note.isEmpty {
                        Text(annotation.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to Highlight")
            .accessibilityLabel("Go to highlight on \(annotation.chapter)")

            if isEditingNote {
                TextEditor(text: $annotation.note)
                    .font(.caption)
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 12) {
                if isEditingNote {
                    Button {
                        isEditingNote = false
                    } label: {
                        Label("Done Editing", systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Done Editing")
                } else {
                    Button {
                        isEditingNote = true
                    } label: {
                        Label(
                            annotation.note.isEmpty ? "Add Note" : "Edit Note",
                            systemImage: annotation.note.isEmpty
                                ? "note.text.badge.plus"
                                : "square.and.pencil"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(annotation.note.isEmpty ? "Add Note" : "Edit Note")
                }

                if let book = store.selectedBook {
                    Button {
                        store.copyQuoteWithCitation(annotation, in: book)
                    } label: {
                        Label("Copy Quote with Citation", systemImage: "quote.opening")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Copy Quote with Citation")
                }

                Spacer()

                Button(role: .destructive) {
                    store.deleteHighlight(annotation, context: modelContext)
                } label: {
                    Label("Delete Highlight", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Delete Highlight")
            }
        }
        .padding(.vertical, 7)
    }
}

struct SettingsView: View {
    @Environment(ReaderStore.self) private var store
    @State private var openAIKeyDraft = ""
    @State private var geminiKeyDraft = ""

    var body: some View {
        @Bindable var store = store

        Form {
            Section("Reading") {
                Picker("Default Theme", selection: $store.readerTheme) {
                    ForEach(ReaderStore.ReaderTheme.allCases) {
                        Text($0.label).tag($0)
                    }
                }
                Slider(value: $store.fontSize, in: 14...28, step: 1) {
                    Text("Text Size")
                }
            }
            Section("Library") {
                LabeledContent("Storage", value: "On this Mac")
                LabeledContent("Publication Scripts", value: "Not executed")
            }
            Section("AI Assistant") {
                Picker("Provider", selection: $store.aiProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Text(store.aiProvider.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch store.aiProvider {
                case .openAI:
                    SecureField(
                        store.openAIKeyPresent
                            ? "Paste a new API key to replace the saved key"
                            : "OpenAI Platform API key",
                        text: $openAIKeyDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(store.openAIConnectionStatus == .working)
                    .onChange(of: store.openAIConnectionStatus) {
                        if store.openAIKeyPresent,
                           store.openAIConnectionStatus == .idle {
                            openAIKeyDraft = ""
                        }
                    }
                    .onSubmit {
                        store.connectOpenAI(openAIKeyDraft)
                    }
                    HStack {
                        Button(store.openAIKeyPresent ? "Replace Key" : "Connect") {
                            store.connectOpenAI(openAIKeyDraft)
                        }
                        .disabled(openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || store.openAIConnectionStatus == .working)
                        if store.openAIConnectionStatus == .working {
                            ProgressView().controlSize(.small)
                        }
                        if store.openAIKeyPresent {
                            Text("API key saved")
                                .foregroundStyle(.secondary)
                            Button("Remove Key") {
                                store.disconnectOpenAI()
                            }
                            .disabled(store.openAIConnectionStatus == .working)
                        }
                    }
                    if case .failed(let message) = store.openAIConnectionStatus {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Link(
                        "Create an OpenAI API key",
                        destination: URL(string: "https://platform.openai.com/api-keys")!
                    )
                    .font(.caption)
                    Picker("Model", selection: $store.openAIModel) {
                        ForEach(AIModelCatalog.options, id: \.id) { option in
                            Text(option.name).tag(option.id)
                        }
                        if !AIModelCatalog.options.contains(where: { $0.id == store.openAIModel }) {
                            Text(store.openAIModel).tag(store.openAIModel)
                        }
                    }
                    TextField("Custom model ID", text: $store.openAIModel)
                        .textFieldStyle(.roundedBorder)
                case .chatGPT:
                    HStack {
                        if store.chatGPTSignedIn {
                            Text("Signed in")
                                .foregroundStyle(.secondary)
                            Button("Sign Out") {
                                store.signOutChatGPT()
                            }
                            .disabled(store.chatGPTAuthStatus == .working)
                        } else {
                            Button("Sign in with ChatGPT…") {
                                store.signInChatGPT()
                            }
                            .disabled(store.chatGPTAuthStatus == .working)
                        }
                        if store.chatGPTAuthStatus == .working {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if case .failed(let message) = store.chatGPTAuthStatus {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Picker("Model", selection: $store.chatGPTModel) {
                        ForEach(AIModelCatalog.options, id: \.id) { option in
                            Text(option.name).tag(option.id)
                        }
                        if !AIModelCatalog.options.contains(where: { $0.id == store.chatGPTModel }) {
                            Text(store.chatGPTModel).tag(store.chatGPTModel)
                        }
                    }
                    TextField("Custom model ID", text: $store.chatGPTModel)
                        .textFieldStyle(.roundedBorder)
                case .gemini:
                    SecureField(
                        store.geminiKeyPresent
                            ? "Paste a new Gemini API key to replace the saved key"
                            : "Gemini API key",
                        text: $geminiKeyDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(store.geminiConnectionStatus == .working)
                    .onChange(of: store.geminiConnectionStatus) {
                        if store.geminiKeyPresent,
                           store.geminiConnectionStatus == .idle {
                            geminiKeyDraft = ""
                        }
                    }
                    .onSubmit { store.connectGemini(geminiKeyDraft) }
                    HStack {
                        Button(store.geminiKeyPresent ? "Replace Key" : "Connect") {
                            store.connectGemini(geminiKeyDraft)
                        }
                        .disabled(geminiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || store.geminiConnectionStatus == .working)
                        if store.geminiKeyPresent {
                            Text("API key saved").foregroundStyle(.secondary)
                            Button("Remove Key") { store.disconnectGeminiKey() }
                                .disabled(store.geminiConnectionStatus == .working)
                        }
                    }
                    Link(
                        "Create a Gemini API key",
                        destination: URL(string: "https://aistudio.google.com/api-keys")!
                    )
                    .font(.caption)
                    if store.geminiConnectionStatus == .working {
                        ProgressView().controlSize(.small)
                    }
                    if case .failed(let message) = store.geminiConnectionStatus {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    Picker("Model", selection: $store.geminiModel) {
                        ForEach(GeminiModelCatalog.options, id: \.id) { option in
                            Text(option.name).tag(option.id)
                        }
                        if !GeminiModelCatalog.options.contains(where: { $0.id == store.geminiModel }) {
                            Text(store.geminiModel).tag(store.geminiModel)
                        }
                    }
                    TextField("Custom model ID", text: $store.geminiModel)
                        .textFieldStyle(.roundedBorder)
                    if store.geminiModel == GeminiModelCatalog.deepResearch {
                        Text("Deep Research can take several minutes and incurs separate API charges per task. It uses Google's background agent and may search external sources.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .appleIntelligence:
                    EmptyView()
                }
            }
            Section("Software Update") {
                LabeledContent(
                    "Current Version",
                    value: UpdateChecker.currentVersion
                )
                if let release = store.availableUpdate {
                    LabeledContent(
                        "Latest Release",
                        value: "v\(release.version)"
                    )
                }
                HStack(spacing: 12) {
                    switch store.updateStatus {
                    case .checking:
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking…")
                    case .available:
                        Button("Download & Install") {
                            store.installAvailableUpdate()
                        }
                        if let url = store.availableUpdate?.htmlURL {
                            Button("View Release") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    case .downloading:
                        ProgressView()
                            .controlSize(.small)
                        Text("Downloading update…")
                    case .installing:
                        Text("Installing — Leaf will relaunch.")
                    case .upToDate:
                        Text("You're up to date.")
                        Button("Check Again") {
                            store.checkForUpdates(userInitiated: true)
                        }
                    case .idle:
                        Button("Check for Updates…") {
                            store.checkForUpdates(userInitiated: true)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .task {
            store.refreshAIConnectionStatus()
        }
        .formStyle(.grouped)
        .padding()
    }
}
