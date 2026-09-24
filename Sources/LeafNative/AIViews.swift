import AppKit
import Markdown
import SwiftData
import SwiftUI

struct CompanionInspector: View {
    @Environment(ReaderStore.self) private var store
    let annotations: [AnnotationRecord]

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Picker("Side pane", selection: $store.companionPane) {
                Text("AI Companion").tag(ReaderStore.CompanionPane.ai)
                Text("Notebook").tag(ReaderStore.CompanionPane.notebook)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            if store.companionPane == .ai {
                AIChatView().environment(store)
            } else {
                NotebookInspector(annotations: annotations)
            }
        }
    }
}

struct AIChatView: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AIThreadRecord.updatedAt, order: .reverse) private var allThreads: [AIThreadRecord]
    @Query(sort: \AIChatMessageRecord.createdAt) private var allMessages: [AIChatMessageRecord]
    @Query private var annotations: [AnnotationRecord]
    @FocusState private var inputFocused: Bool
    @State private var selectedThreadID: UUID?
    @State private var requestTask: Task<Void, Never>?

    private var book: BookRecord? { store.selectedBook }
    private var companionAccent: Color {
        colorScheme == .dark ? LeafPalette.amberSoft : LeafPalette.amber
    }
    private var threads: [AIThreadRecord] {
        allThreads.filter { $0.bookID == book?.id }
    }
    private var activeThread: AIThreadRecord? {
        threads.first { $0.id == selectedThreadID } ?? threads.first
    }
    private var messages: [AIChatMessageRecord] {
        allMessages.filter { $0.threadID == activeThread?.id }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            selectedThreadID = threads.first?.id
            inputFocused = true
        }
        .onChange(of: book?.id) { selectedThreadID = threads.first?.id }
        .onChange(of: store.aiAutoSendTrigger) { send() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.book.closed")
                .foregroundStyle(companionAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(book?.title ?? "AI Companion")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(activeThread?.title ?? "New conversation")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            modelMenu
            Menu {
                Button("New Conversation", systemImage: "plus") { newThread() }
                Divider()
                ForEach(threads) { thread in
                    Button(thread.title) { selectedThreadID = thread.id }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .help("Conversations for this book")
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private var modelMenu: some View {
        Menu {
            if store.aiProvider == .appleIntelligence {
                Text("Apple Intelligence")
            } else if store.aiProvider == .gemini {
                ForEach(GeminiModelCatalog.options, id: \.id) { model in
                    Button(model.name) { store.geminiModel = model.id }
                }
            } else {
                ForEach(AIModelCatalog.options, id: \.id) { model in
                    Button(model.name) {
                        if store.aiProvider == .chatGPT {
                            store.chatGPTModel = model.id
                        } else {
                            store.openAIModel = model.id
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "sparkles")
        }
        .menuStyle(.borderlessButton)
        .help("\(store.aiProvider.displayName) · \(store.activeModelLabel)")
        .accessibilityLabel("AI model: \(store.activeModelLabel)")
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if messages.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "sparkles")
                                .font(.title2).foregroundStyle(companionAccent)
                            Text("Read with a second mind.").font(.title3.weight(.semibold))
                            Text("Ask about this document, select a passage, or find related papers. Answers can lead you back to the page.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("Summarize this section") { store.summarizeSection() }
                                .buttonStyle(.bordered)
                        }
                        .padding(.top, 30)
                    }
                    ForEach(messages) { message in
                        AIConversationMessage(message: message, bookHash: store.researchContentHash)
                            .environment(store)
                            .id(message.id)
                    }
                }
                .padding(20)
            }
            .onChange(of: allMessages.count) {
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 8) {
            if !store.aiContextQuote.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "text.quote").foregroundStyle(companionAccent)
                    Text("Selected passage").font(.caption.weight(.medium))
                    Text(store.aiContextQuote)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        store.aiContextQuote = ""
                        store.aiContextLocator = ""
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove selected passage")
                }
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            HStack(alignment: .bottom, spacing: 9) {
                Menu {
                    Button("Summarize this section") { store.summarizeSection() }
                    Button("Quiz me on my highlights") {
                        store.quizFromHighlights(
                            annotations.filter { $0.bookID == book?.id }.map(\.quote)
                        )
                    }
                    Button("Find related papers") {
                        store.aiDraft = "Find papers related to this passage"
                        send()
                    }
                } label: {
                    Image(systemName: "plus.circle").font(.title3)
                }
                .menuStyle(.borderlessButton)

                TextField("Ask about this document…", text: $store.aiDraft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { send() }
                    .frame(maxWidth: .infinity)
                if store.aiStatus == .working {
                    Button { stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .help("Stop response")
                } else {
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2).foregroundStyle(companionAccent)
                    }
                    .disabled(store.aiDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send question")
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            HStack {
                Text("Return to send")
                Spacer()
                if let last = messages.last, !last.errorText.isEmpty,
                   store.aiStatus != .working {
                    Button("Retry") { retry() }.buttonStyle(.plain)
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
    }

    @MainActor private func newThread() {
        guard let book else { return }
        let thread = AIThreadRecord(bookID: book.id)
        modelContext.insert(thread)
        selectedThreadID = thread.id
        inputFocused = true
    }

    @MainActor private func send() {
        let question = store.aiDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, store.aiStatus != .working, let book else { return }
        guard !store.isLoading else {
            store.showToast("Wait for the book to finish opening")
            return
        }
        store.aiDraft = ""
        let thread: AIThreadRecord
        if let activeThread { thread = activeThread }
        else {
            thread = AIThreadRecord(bookID: book.id)
            modelContext.insert(thread)
            selectedThreadID = thread.id
        }
        if thread.title == "New conversation" { thread.title = String(question.prefix(52)) }
        thread.updatedAt = .now
        modelContext.insert(AIChatMessageRecord(threadID: thread.id, role: "user", text: question))
        startResponse(question: question, thread: thread)
    }

    @MainActor private func retry() {
        guard store.aiStatus != .working, let thread = activeThread,
              let question = messages.last(where: { $0.roleRaw == "user" })?.text
        else { return }
        startResponse(question: question, thread: thread)
    }

    @MainActor private func stop() {
        requestTask?.cancel()
        requestTask = nil
        store.aiStatus = .idle
    }

    @MainActor private func startResponse(question: String, thread: AIThreadRecord) {
        guard let book else { return }
        let assistant = AIChatMessageRecord(
            threadID: thread.id, role: "assistant", text: "",
            providerRaw: store.aiProvider.rawValue, modelID: store.activeModelID,
            contentHash: store.researchContentHash
        )
        modelContext.insert(assistant)
        let client = Result { try store.makeAIClient() }
        store.aiStatus = .working
        let selected = store.aiContextPassage
            ?? store.selectedPassage()
            ?? store.currentReadingPassage()
        let documentText = store.extractedResearchText
        let history = messages.suffix(10)
            .map { "\($0.roleRaw): \($0.text)" }.joined(separator: "\n\n")
        let bookID = book.id
        let bookHash = store.researchContentHash
        let bookTitle = book.title
        let format = book.format
        let url = book.fileURL

        requestTask = Task { @MainActor in
            do {
                let citations = await ResearchIndex.shared.search(
                    bookID: bookID, contentHash: bookHash, format: format,
                    url: url, extractedText: documentText,
                    question: question, selected: selected
                )
                try Task.checkCancellation()
                assistant.citations = citations
                if ResearchIntent.wantsPapers(question),
                   assistant.modelID != GeminiModelCatalog.deepResearch {
                    let query = ResearchIntent.query(
                        question: question, selectedQuote: selected?.text ?? ""
                    )
                    let papers = try await PaperSearch.shared.search(query: query)
                    try Task.checkCancellation()
                    assistant.papers = papers
                    assistant.text = papers.isEmpty
                        ? "I couldn't confirm matching paper metadata. Try a more specific question."
                        : "I found \(papers.count) papers with confirmed bibliographic details. Open a paper to examine its findings."
                } else {
                    let evidence = citations.map {
                        "[\($0.id)] \($0.label), locator \($0.locator): \($0.quote)"
                    }.joined(separator: "\n\n")
                    let prompt = """
                        Book: \(bookTitle)
                        Question: \(question)

                        Earlier conversation (for continuity only):
                        \(history)

                        Retrieved document passages:
                        \(evidence.isEmpty ? "No extractable passages were found." : evidence)

                        Answer using Markdown. For longer answers, start with a short takeaway, then use brief headings and lists for the findings. Keep simple answers concise. Cite claims about the book using only the source IDs above, formatted [S1]. Never invent source IDs or external papers. If passages do not support an answer, say so.
                        """
                    let selectedClient = try client.get()
                    for try await delta in selectedClient.stream(
                        system: assistant.modelID == GeminiModelCatalog.deepResearch
                            ? ReaderStore.deepResearchSystemPrompt
                            : ReaderStore.aiSystemPrompt,
                        prompt: prompt
                    ) {
                        try Task.checkCancellation()
                        assistant.text += delta
                    }
                    if assistant.text.isEmpty { throw AIError.badResponse }
                }
                store.aiStatus = .idle
                requestTask = nil
            } catch is CancellationError {
                assistant.errorText = "Stopped"
                store.aiStatus = .idle
                requestTask = nil
            } catch {
                if Task.isCancelled {
                    assistant.errorText = "Stopped"
                    store.aiStatus = .idle
                } else {
                    assistant.errorText = error.localizedDescription
                    store.aiStatus = .failed(error.localizedDescription)
                }
                requestTask = nil
            }
        }
    }
}

private struct AIConversationMessage: View {
    @Environment(ReaderStore.self) private var store
    @State private var sourcesExpanded = false
    @State private var externalSourcesExpanded = false
    let message: AIChatMessageRecord
    let bookHash: String

    private var researchSections: (answer: String, sources: [ExternalResearchSource]) {
        ResearchSourceLinks.split(message.text)
    }

    private var citedText: String {
        ResearchCitationLinks.linkify(researchSections.answer, citations: message.citations)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.roleRaw == "user" {
                Text(message.text)
                    .font(.body).textSelection(.enabled).padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            } else {
                if !message.text.isEmpty {
                    NativeMarkdownView(source: citedText) { url in
                        if url.scheme == "leaf-citation", let id = url.host,
                           let citation = message.citations.first(where: { $0.id == id }) {
                            store.navigate(to: citation)
                        } else if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else if message.errorText.isEmpty {
                    ProgressView(
                        message.modelID == GeminiModelCatalog.deepResearch
                            ? "Researching sources… This can take several minutes."
                            : "Thinking…"
                    ).controlSize(.small)
                }
                if !message.errorText.isEmpty {
                    Label(message.errorText, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !message.citations.isEmpty { sources }
                if !researchSections.sources.isEmpty { externalSources }
                if !message.papers.isEmpty { papers }
                if !message.text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sources: some View {
        DisclosureGroup(isExpanded: $sourcesExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.citations) { citation in
                    Button { store.navigate(to: citation) } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Text(String(citation.id.dropFirst()))
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .frame(width: 22, height: 22)
                                .background(LeafPalette.sage.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(citation.label).font(.caption.weight(.semibold))
                                Text(citation.quote).font(.caption).lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.turn.down.right").font(.caption2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(citation.contentHash != bookHash)
                    if citation.contentHash != bookHash {
                        Text("Source changed; this link is stale")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Document sources · \(message.citations.count)", systemImage: "text.book.closed")
                .font(.caption.weight(.medium))
        }
        .padding(.top, 8)
    }

    private var externalSources: some View {
        DisclosureGroup(isExpanded: $externalSourcesExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(researchSections.sources) { source in
                    Link(destination: source.url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title).font(.caption.weight(.medium))
                            Text(source.url.host ?? source.url.absoluteString)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("External sources · \(researchSections.sources.count)", systemImage: "link")
                .font(.caption.weight(.medium))
        }
        .padding(.top, 8)
    }

    private var papers: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Related papers", systemImage: "books.vertical")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(message.papers) { paper in
                VStack(alignment: .leading, spacing: 4) {
                    Link(destination: paper.landingURL) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(paper.title)
                            Image(systemName: "arrow.up.right").font(.caption2)
                        }
                        .font(.subheadline.weight(.medium))
                    }
                    Text("\(paper.authors) · \(paper.year.map(String.init) ?? "Year unknown")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let relevanceNote = paper.relevanceNote {
                        Text(relevanceNote)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("DOI: \(paper.doi)")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        Link("Open paper", destination: paper.landingURL)
                        if let pdfURL = paper.pdfURL {
                            Link("Open PDF", destination: pdfURL)
                        }
                        Button("Copy citation") { copyCitation(paper) }
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    Button("Import downloaded PDF…") { store.importerVisible = true }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(.top, 8)
    }

    private func copyCitation(_ paper: PaperResult) {
        let year = paper.year.map { " (\($0))." } ?? "."
        let citation = "\(paper.authors)\(year) \(paper.title). \(paper.landingURL.absoluteString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(citation, forType: .string)
        store.showToast("Citation copied")
    }
}

struct NativeMarkdownView: View {
    @Environment(\.colorScheme) private var colorScheme
    let source: String
    let openLink: (URL) -> Void

    var body: some View {
        let blocks = Array(Document(parsing: source).children)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if let heading = block as? Heading {
                    inline(
                        heading.children.map { $0.format() }.joined(),
                        font: heading.level == 1 ? .title3.weight(.semibold)
                            : heading.level == 2 ? .headline : .subheadline.weight(.semibold)
                    )
                    .padding(.top, 4)
                } else if let code = block as? CodeBlock {
                    Text(code.code)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                } else if let quote = block as? BlockQuote {
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle()
                            .fill(LeafPalette.sage)
                            .frame(width: 3)
                        inline(quote.children.map { $0.format() }.joined(separator: "\n"))
                            .foregroundStyle(.secondary)
                    }
                } else if block is UnorderedList || block is OrderedList {
                    listView(block)
                } else if let table = block as? Markdown.Table {
                    tableView(table)
                } else {
                    inline(block.format())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listView(_ list: Markup) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(list.children.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(list is OrderedList ? "\(index + 1)." : "•")
                        .foregroundStyle(colorScheme == .dark ? LeafPalette.amberSoft : LeafPalette.amber)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            if child is UnorderedList || child is OrderedList {
                                listView(child)
                            } else {
                                inline(child.format())
                            }
                        }
                    }
                }
            }
        })
    }

    private func tableView(_ table: Markdown.Table) -> some View {
        let header = Array(table.head.children).map { $0.format() }
        let rows = Array(table.body.rows).map { row in
            Array(row.children).map { $0.format() }
        }
        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        inline(cell).fontWeight(.semibold)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inline(cell)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }

    private func inline(_ source: String, font: Font = .body) -> some View {
        let attributed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        return Text(attributed)
            .font(font).lineSpacing(3).textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                openLink(url)
                return .handled
            })
    }
}
