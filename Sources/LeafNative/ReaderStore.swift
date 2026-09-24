import AppKit
import Observation
import PDFKit
import SwiftData
import SwiftUI

private enum PDFHighlightIdentity {
    static func tag(for annotationID: UUID) -> String {
        "leaf:\(annotationID.uuidString)"
    }

    @discardableResult
    static func remove(
        annotationID: UUID,
        quote: String,
        from page: PDFPage
    ) -> Int {
        let tag = tag(for: annotationID)
        let highlightType = PDFAnnotationSubtype.highlight.rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let highlights = page.annotations.filter {
            $0.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == highlightType
        }
        let tagged = highlights.filter { $0.contents == tag }
        let matches: [PDFAnnotation]

        if tagged.isEmpty {
            let normalizedQuote = normalize(quote)
            matches = highlights.filter { annotation in
                guard let fragment = page.selection(for: annotation.bounds)?.string else {
                    return false
                }
                let normalizedFragment = normalize(fragment)
                return normalizedFragment.count >= 3
                    && normalizedQuote.contains(normalizedFragment)
            }
        } else {
            matches = tagged
        }

        for annotation in matches {
            page.removeAnnotation(annotation)
        }
        return matches.count
    }

    private static func normalize(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

private actor PDFHighlightPersistence {
    struct Mark: Sendable {
        let pageIndex: Int
        let bounds: CGRect
    }

    static let shared = PDFHighlightPersistence()

    func save(
        marks: [Mark],
        color: HighlightColor,
        annotationID: UUID,
        to url: URL
    ) -> Bool {
        guard let document = PDFDocument(url: url) else { return false }

        for mark in marks {
            guard let page = document.page(at: mark.pageIndex) else { continue }
            let annotation = PDFAnnotation(
                bounds: mark.bounds,
                forType: .highlight,
                withProperties: nil
            )
            annotation.color = color.nsColor.withAlphaComponent(0.34)
            annotation.contents = PDFHighlightIdentity.tag(for: annotationID)
            page.addAnnotation(annotation)
        }

        return writeAtomically(document, to: url)
    }

    private func writeAtomically(
        _ document: PDFDocument,
        to url: URL
    ) -> Bool {
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        guard document.write(to: tempURL) else { return false }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }

    func delete(
        annotationID: UUID,
        pageIndex: Int,
        quote: String,
        from url: URL
    ) -> Bool {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex)
        else { return false }

        PDFHighlightIdentity.remove(
            annotationID: annotationID,
            quote: quote,
            from: page
        )
        return writeAtomically(document, to: url)
    }
}

@MainActor
@Observable
final class ReaderStore {
    struct LocationNavigation: Equatable {
        let requestID = UUID()
        let bookID: UUID
        let locator: String
    }

    var destination: SidebarDestination = .reader
    var selectedBook: BookRecord?
    var columnVisibility: NavigationSplitViewVisibility = .all
    var inspectorVisible = true
    var inspectorTab = 0
    enum CompanionPane { case notebook, ai }
    var companionPane: CompanionPane = .notebook
    var importerVisible = false
    var appearanceVisible = false
    var searchText = ""
    var loadedContent: LoadedBookContent?
    var researchContentHash = ""
    var contents: [BookContentEntry] = []
    var activeContentEntryID: String?
    var isLoading = false
    var loadingError: String?
    var selectedTextRange = NSRange(location: NSNotFound, length: 0)
    var selectedTextQuote = ""
    var activePDFView: PDFView?
    /// Books whose DOI lookup finished without a match this session.
    var settledCitationLookups: Set<UUID> = []
    var doiPromptBook: BookRecord?
    var doiPromptText = ""
    var locationNavigation: LocationNavigation?
    var toast: String?
    var updateStatus: UpdateStatus = .idle
    var availableUpdate: GitHubRelease?
    var updateAlertVisible = false

    var aiStatus: AIStatus = .idle
    var aiDraft = ""
    var aiContextQuote = ""
    var aiContextLocator = ""
    var aiContextLabel = ""
    var aiAutoSendTrigger = 0
    var chatGPTSignedIn = UserDefaults.standard.bool(forKey: "leaf.ai.chatGPTConnected")
    var chatGPTAuthStatus: AIStatus = .idle
    var openAIKeyPresent = UserDefaults.standard.bool(forKey: "leaf.ai.openAIConnected")
    var openAIConnectionStatus: AIStatus = .idle
    var geminiKeyPresent = UserDefaults.standard.bool(forKey: "leaf.ai.geminiKeyConnected")
    var geminiConnectionStatus: AIStatus = .idle

    init() {
        // Remove credentials from the discontinued Google OAuth integration.
        KeychainStore.remove(account: "gemini-oauth-client")
        KeychainStore.remove(account: "gemini-oauth-credentials")
        UserDefaults.standard.removeObject(forKey: "leaf.ai.geminiAuthMethod")
        UserDefaults.standard.removeObject(forKey: "leaf.ai.geminiOAuthConfigured")
        UserDefaults.standard.removeObject(forKey: "leaf.ai.geminiSignedIn")
    }

    private enum Defaults {
        static let fontSize = "leaf.appearance.fontSize"
        static let lineSpacing = "leaf.appearance.lineSpacing"
        static let pageWidth = "leaf.appearance.pageWidth"
        static let theme = "leaf.appearance.theme"
        static let librarySort = "leaf.librarySort"
        static let aiProvider = "leaf.ai.provider"
        static let openAIModel = "leaf.ai.openAIModel"
        static let chatGPTModel = "leaf.ai.chatGPTModel"
        static let geminiModel = "leaf.ai.geminiModel"
    }

    var aiProvider: AIProvider {
        get {
            access(keyPath: \.aiProvider)
            return AIProvider(
                rawValue: UserDefaults.standard
                    .string(forKey: Defaults.aiProvider) ?? ""
            ) ?? .appleIntelligence
        }
        set {
            withMutation(keyPath: \.aiProvider) {
                UserDefaults.standard.set(
                    newValue.rawValue, forKey: Defaults.aiProvider
                )
            }
        }
    }

    var openAIModel: String {
        get {
            access(keyPath: \.openAIModel)
            return UserDefaults.standard
                .string(forKey: Defaults.openAIModel) ?? AIModelCatalog.defaultModel
        }
        set {
            withMutation(keyPath: \.openAIModel) {
                UserDefaults.standard.set(
                    newValue, forKey: Defaults.openAIModel
                )
            }
        }
    }

    var chatGPTModel: String {
        get {
            access(keyPath: \.chatGPTModel)
            // The first assistant build used this as its default without a picker.
            guard let saved = UserDefaults.standard.string(forKey: Defaults.chatGPTModel),
                  saved != "gpt-5.4-mini"
            else { return AIModelCatalog.defaultModel }
            return saved
        }
        set {
            withMutation(keyPath: \.chatGPTModel) {
                UserDefaults.standard.set(newValue, forKey: Defaults.chatGPTModel)
            }
        }
    }

    var geminiModel: String {
        get {
            access(keyPath: \.geminiModel)
            return UserDefaults.standard.string(forKey: Defaults.geminiModel)
                ?? GeminiModelCatalog.defaultModel
        }
        set {
            withMutation(keyPath: \.geminiModel) {
                UserDefaults.standard.set(newValue, forKey: Defaults.geminiModel)
            }
        }
    }

    var fontSize: CGFloat {
        get {
            access(keyPath: \.fontSize)
            return (UserDefaults.standard.object(forKey: Defaults.fontSize) as? Double)
                .map { CGFloat($0) } ?? 18
        }
        set {
            withMutation(keyPath: \.fontSize) {
                UserDefaults.standard.set(Double(newValue), forKey: Defaults.fontSize)
            }
        }
    }

    var lineSpacing: CGFloat {
        get {
            access(keyPath: \.lineSpacing)
            return (UserDefaults.standard.object(forKey: Defaults.lineSpacing) as? Double)
                .map { CGFloat($0) } ?? 8
        }
        set {
            withMutation(keyPath: \.lineSpacing) {
                UserDefaults.standard.set(
                    Double(newValue),
                    forKey: Defaults.lineSpacing
                )
            }
        }
    }

    var pageWidth: CGFloat {
        get {
            access(keyPath: \.pageWidth)
            return (UserDefaults.standard.object(forKey: Defaults.pageWidth) as? Double)
                .map { CGFloat($0) } ?? 680
        }
        set {
            withMutation(keyPath: \.pageWidth) {
                UserDefaults.standard.set(Double(newValue), forKey: Defaults.pageWidth)
            }
        }
    }

    var readerTheme: ReaderTheme {
        get {
            access(keyPath: \.readerTheme)
            return UserDefaults.standard.string(forKey: Defaults.theme)
                .flatMap(ReaderTheme.init(rawValue:)) ?? .paper
        }
        set {
            withMutation(keyPath: \.readerTheme) {
                UserDefaults.standard.set(newValue.rawValue, forKey: Defaults.theme)
            }
        }
    }

    var librarySort: LibrarySort {
        get {
            access(keyPath: \.librarySort)
            return UserDefaults.standard.string(forKey: Defaults.librarySort)
                .flatMap(LibrarySort.init(rawValue:)) ?? .lastOpened
        }
        set {
            withMutation(keyPath: \.librarySort) {
                UserDefaults.standard.set(newValue.rawValue, forKey: Defaults.librarySort)
            }
        }
    }

    enum ReaderTheme: String, CaseIterable, Identifiable {
        case paper
        case sepia
        case night

        var id: Self { self }

        var label: String {
            rawValue.capitalized
        }
    }

    enum LibrarySort: String, CaseIterable, Identifiable {
        case lastOpened
        case title
        case author

        var id: Self { self }

        var label: String {
            switch self {
            case .lastOpened: "Last Opened"
            case .title: "Title"
            case .author: "Author"
            }
        }
    }

    func select(_ book: BookRecord) {
        selectedBook = book
        book.lastOpened = .now
        destination = .reader
        searchText = ""
        selectedTextRange = NSRange(location: NSNotFound, length: 0)
        selectedTextQuote = ""
        activePDFView = nil
        researchContentHash = ""
        contents = []
        activeContentEntryID = nil
        locationNavigation = nil
    }

    func navigate(
        to annotation: AnnotationRecord,
        in book: BookRecord? = nil
    ) {
        if let book, selectedBook?.id != book.id {
            select(book)
        } else {
            destination = .reader
        }

        locationNavigation = LocationNavigation(
            bookID: annotation.bookID,
            locator: annotation.locator
        )
    }

    func setContents(_ entries: [BookContentEntry]) {
        contents = entries
        activeContentEntryID = entries.first?.id
    }

    func navigate(to entry: BookContentEntry) {
        guard let book = selectedBook else { return }
        destination = .reader
        activeContentEntryID = entry.id
        locationNavigation = LocationNavigation(
            bookID: book.id,
            locator: entry.locator
        )
    }

    func updateCurrentPDFSection(pageIndex: Int) -> String? {
        let current = contents.last {
            guard let entryPage = $0.pdfPageIndex else { return false }
            return entryPage <= pageIndex
        }
        activeContentEntryID = current?.id
        return current?.title
    }

    func updateCurrentTextSection(charIndex: Int) -> String? {
        let current = contents.last {
            guard let offset = $0.textOffset else { return false }
            return offset <= charIndex
        }
        activeContentEntryID = current?.id
        return current?.title
    }

    func toggleBookmark(on book: BookRecord) {
        book.isBookmarked.toggle()
        if book.isBookmarked {
            book.bookmarkLocator = book.lastLocator.isEmpty
                ? Self.startLocator(for: book.format)
                : book.lastLocator
        } else {
            book.bookmarkLocator = ""
        }
        showToast(book.isBookmarked ? "Page bookmarked" : "Bookmark removed")
    }

    func checkForUpdates(userInitiated: Bool) {
        guard updateStatus != .checking else { return }
        updateStatus = .checking
        Task {
            do {
                guard let release = try await UpdateChecker.latestRelease() else {
                    availableUpdate = nil
                    updateStatus = .upToDate
                    if userInitiated {
                        showToast("Leaf is up to date")
                    }
                    return
                }
                if UpdateChecker.isNewer(
                    release.version,
                    than: UpdateChecker.currentVersion
                ) {
                    availableUpdate = release
                    updateStatus = .available
                    updateAlertVisible = true
                } else {
                    availableUpdate = nil
                    updateStatus = .upToDate
                    if userInitiated {
                        showToast("Leaf is up to date")
                    }
                }
            } catch {
                updateStatus = .idle
                if userInitiated {
                    showToast(error.localizedDescription)
                }
            }
        }
    }

    func installAvailableUpdate() {
        guard let release = availableUpdate,
              updateStatus == .available
        else { return }
        updateAlertVisible = false
        updateStatus = .downloading
        Task {
            do {
                updateStatus = .installing
                try await UpdateChecker.downloadAndInstall(release)
            } catch {
                updateStatus = .available
                showToast(error.localizedDescription)
            }
        }
    }

    private static func startLocator(for format: ReaderFormat) -> String {
        switch format {
        case .pdf:
            "pdf:0"
        case .cbz, .cbr, .unknown:
            ""
        default:
            "text:0:0"
        }
    }

    func navigateToBookmark(in book: BookRecord) {
        guard book.isBookmarked, !book.bookmarkLocator.isEmpty else { return }
        locationNavigation = LocationNavigation(
            bookID: book.id,
            locator: book.bookmarkLocator
        )
    }

    func showToast(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if toast == message {
                toast = nil
            }
        }
    }

    func previousPage() {
        if let pdfView = activePDFView {
            pdfView.goToPreviousPage(nil)
        }
    }

    func nextPage() {
        if let pdfView = activePDFView {
            pdfView.goToNextPage(nil)
        }
    }

    func addHighlight(
        color: HighlightColor,
        context: ModelContext
    ) {
        guard let book = selectedBook else { return }

        if book.format == .pdf, let pdfView = activePDFView,
           let selection = pdfView.currentSelection,
           let quote = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !quote.isEmpty {
            let recordID = UUID()
            var marks: [PDFHighlightPersistence.Mark] = []
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let bounds = line.bounds(for: page)
                    let annotation = PDFAnnotation(
                        bounds: bounds,
                        forType: .highlight,
                        withProperties: nil
                    )
                    annotation.color = color.nsColor.withAlphaComponent(0.34)
                    annotation.contents = PDFHighlightIdentity.tag(for: recordID)
                    page.addAnnotation(annotation)

                    if let document = pdfView.document {
                        marks.append(
                            PDFHighlightPersistence.Mark(
                                pageIndex: document.index(for: page),
                                bounds: bounds
                            )
                        )
                    }
                }
            }

            let pageIndex = selection.pages.first.flatMap {
                pdfView.document?.index(for: $0)
            } ?? 0
            let record = AnnotationRecord(
                id: recordID,
                bookID: book.id,
                quote: quote,
                color: color,
                locator: "pdf:\(pageIndex)",
                chapter: book.currentChapter
            )
            context.insert(record)
            if let url = book.fileURL {
                Task {
                    let didSave = await PDFHighlightPersistence.shared.save(
                        marks: marks,
                        color: color,
                        annotationID: recordID,
                        to: url
                    )
                    if !didSave {
                        showToast("Highlight saved, but the PDF could not be updated")
                    }
                }
            }
            pdfView.clearSelection()
            showToast("Highlight saved")
            return
        }

        guard selectedTextRange.location != NSNotFound,
              selectedTextRange.length > 0,
              !selectedTextQuote.isEmpty
        else {
            showToast("Select text first")
            return
        }

        let record = AnnotationRecord(
            bookID: book.id,
            quote: selectedTextQuote,
            color: color,
            locator: "text:\(selectedTextRange.location):\(selectedTextRange.length)",
            chapter: book.currentChapter
        )
        context.insert(record)
        selectedTextRange = NSRange(location: NSNotFound, length: 0)
        selectedTextQuote = ""
        showToast("Highlight saved")
    }

    func deleteHighlight(
        _ annotation: AnnotationRecord,
        context: ModelContext
    ) {
        let annotationID = annotation.id
        let quote = annotation.quote
        let locator = annotation.locator

        if let book = selectedBook,
           book.id == annotation.bookID,
           book.format == .pdf,
           let pageIndex = pdfPageIndex(from: locator) {
            if let page = activePDFView?.document?.page(at: pageIndex) {
                PDFHighlightIdentity.remove(
                    annotationID: annotationID,
                    quote: quote,
                    from: page
                )
            }

            if let url = book.fileURL {
                Task {
                    let didDelete = await PDFHighlightPersistence.shared.delete(
                        annotationID: annotationID,
                        pageIndex: pageIndex,
                        quote: quote,
                        from: url
                    )
                    if !didDelete {
                        showToast("Highlight removed, but the PDF could not be updated")
                    }
                }
            }
        }

        context.delete(annotation)
        showToast("Highlight deleted")
    }

    func addNote(context: ModelContext) {
        addHighlight(color: .amber, context: context)
        inspectorVisible = true
        inspectorTab = 1
    }

    // MARK: AI assistant

    var selectedQuote: String {
        if selectedBook?.format == .pdf,
           let pdfQuote = activePDFView?.currentSelection?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !pdfQuote.isEmpty {
            return pdfQuote
        }
        return selectedTextQuote
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func askAboutSelection() {
        let quote = selectedQuote
        guard !quote.isEmpty else {
            showToast("Select text first")
            return
        }
        aiContextQuote = quote
        let passage = selectedPassage()
        aiContextLocator = passage?.locator ?? ""
        aiContextLabel = passage?.label ?? "Selected passage"
        openAICompanion()
    }

    func openAICompanion() {
        companionPane = .ai
        inspectorVisible = true
    }

    func summarizeSection() {
        aiContextQuote = ""
        aiContextLocator = ""
        openAICompanion()
        aiDraft = "Summarize this section into its key points."
        aiAutoSendTrigger += 1
    }

    func quizFromHighlights(_ quotes: [String]) {
        guard !quotes.isEmpty else {
            showToast("No highlights yet")
            return
        }
        aiContextQuote = ""
        aiContextLocator = ""
        openAICompanion()
        let joined = quotes.prefix(12).joined(separator: "\n- ")
        aiDraft = "Quiz me on these highlights from \(selectedBook?.title ?? "this book"). Write 5 short review questions without answers:\n- \(joined)"
        aiAutoSendTrigger += 1
    }

    func connectOpenAI(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, openAIConnectionStatus != .working else { return }
        openAIConnectionStatus = .working
        Task {
            do {
                try await OpenAIClient(apiKey: trimmed).validateKey()
                guard KeychainStore.set(trimmed, account: "openai-api-key") else {
                    throw AIError.requestFailed("Could not save the API key in Keychain.")
                }
                openAIKeyPresent = true
                UserDefaults.standard.set(true, forKey: "leaf.ai.openAIConnected")
                openAIConnectionStatus = .idle
                showToast("OpenAI connected")
            } catch {
                openAIConnectionStatus = .failed(error.localizedDescription)
            }
        }
    }

    func disconnectOpenAI() {
        if KeychainStore.remove(account: "openai-api-key") {
            openAIKeyPresent = false
            UserDefaults.standard.set(false, forKey: "leaf.ai.openAIConnected")
            openAIConnectionStatus = .idle
        } else {
            openAIConnectionStatus = .failed("Could not remove the API key from Keychain.")
        }
    }

    func connectGemini(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, geminiConnectionStatus != .working else { return }
        geminiConnectionStatus = .working
        Task {
            do {
                try await GeminiClient.validate(auth: .apiKey(trimmed))
                guard KeychainStore.set(trimmed, account: "gemini-api-key") else {
                    throw AIError.authFailed("Could not save the Gemini API key in Keychain.")
                }
                geminiKeyPresent = true
                UserDefaults.standard.set(true, forKey: "leaf.ai.geminiKeyConnected")
                geminiConnectionStatus = .idle
                showToast("Gemini API key connected")
            } catch {
                geminiConnectionStatus = .failed(error.localizedDescription)
            }
        }
    }

    func disconnectGeminiKey() {
        if KeychainStore.remove(account: "gemini-api-key") {
            geminiKeyPresent = false
            UserDefaults.standard.set(false, forKey: "leaf.ai.geminiKeyConnected")
            geminiConnectionStatus = .idle
        } else {
            geminiConnectionStatus = .failed("Could not remove the Gemini API key from Keychain.")
        }
    }

    func refreshAIConnectionStatus() {
        Task { [weak self] in
            let presence = await Task.detached {
                (
                    ChatGPTAuth.credentials != nil,
                    KeychainStore.get(account: "openai-api-key") != nil,
                    KeychainStore.get(account: "gemini-api-key") != nil
                )
            }.value
            guard let self else { return }
            chatGPTSignedIn = presence.0
            openAIKeyPresent = presence.1
            geminiKeyPresent = presence.2
            UserDefaults.standard.set(presence.0, forKey: "leaf.ai.chatGPTConnected")
            UserDefaults.standard.set(presence.1, forKey: "leaf.ai.openAIConnected")
            UserDefaults.standard.set(presence.2, forKey: "leaf.ai.geminiKeyConnected")
        }
    }

    func signInChatGPT() {
        guard chatGPTAuthStatus != .working else { return }
        chatGPTAuthStatus = .working
        Task {
            do {
                _ = try await ChatGPTAuth.signIn()
                chatGPTSignedIn = true
                UserDefaults.standard.set(true, forKey: "leaf.ai.chatGPTConnected")
                chatGPTAuthStatus = .idle
                showToast("Signed in to ChatGPT")
            } catch {
                chatGPTAuthStatus = .failed(error.localizedDescription)
            }
        }
    }

    func signOutChatGPT() {
        ChatGPTAuth.signOut()
        chatGPTSignedIn = false
        UserDefaults.standard.set(false, forKey: "leaf.ai.chatGPTConnected")
        chatGPTAuthStatus = .idle
    }

    static let aiSystemPrompt = """
        You are a reading assistant inside Leaf Native, a macOS book reader. \
        Answer concisely, refer to the quoted passage or section when \
        relevant, and keep responses under 300 words unless asked for more.
        """

    static let deepResearchSystemPrompt = """
        You are a research assistant inside Leaf Native. Produce a useful, detailed research report. \
        Distinguish what the open document says from findings in external sources. \
        Cite the supplied document passage IDs for claims about the book and link external sources. \
        Never invent passage IDs, papers, or URLs.
        """

    func makeAIClient() throws -> AIClient {
        switch aiProvider {
        case .openAI:
            guard let key = KeychainStore.get(account: "openai-api-key"),
                  !openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                openAIKeyPresent = false
                UserDefaults.standard.set(false, forKey: "leaf.ai.openAIConnected")
                throw AIError.requestFailed(
                    "Add an OpenAI API key and choose a model in Settings → AI."
                )
            }
            return OpenAIClient(
                apiKey: key,
                model: openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .chatGPT:
            guard let credentials = ChatGPTAuth.credentials else {
                chatGPTSignedIn = false
                UserDefaults.standard.set(false, forKey: "leaf.ai.chatGPTConnected")
                throw AIError.authFailed("Sign in to ChatGPT in Settings → AI.")
            }
            chatGPTSignedIn = true
            UserDefaults.standard.set(true, forKey: "leaf.ai.chatGPTConnected")
            let model = chatGPTModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else {
                throw AIError.requestFailed("Choose a ChatGPT model in Settings → AI.")
            }
            return ChatGPTClient(credentials: credentials, model: model)
        case .gemini:
            let model = geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else {
                throw AIError.requestFailed("Choose a Gemini model in Settings → AI.")
            }
            guard let key = KeychainStore.get(account: "gemini-api-key") else {
                geminiKeyPresent = false
                throw AIError.authFailed("Add a Gemini API key in Settings → AI.")
            }
            return GeminiClient(auth: .apiKey(key), model: model)
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *),
               AppleIntelligenceClient.isAvailable {
                return AppleIntelligenceClient()
            }
            #endif
            throw AIError.appleIntelligenceUnavailable
        }
    }

    var activeModelLabel: String {
        switch aiProvider {
        case .appleIntelligence: "Apple Intelligence"
        case .openAI: AIModelCatalog.options.first(where: { $0.id == openAIModel })?.name ?? openAIModel
        case .chatGPT: AIModelCatalog.options.first(where: { $0.id == chatGPTModel })?.name ?? chatGPTModel
        case .gemini: GeminiModelCatalog.label(for: geminiModel)
        }
    }

    var activeModelID: String {
        switch aiProvider {
        case .appleIntelligence: "apple-intelligence"
        case .openAI: openAIModel
        case .chatGPT: chatGPTModel
        case .gemini: geminiModel
        }
    }

    func selectedPassage() -> IndexedPassage? {
        let quote = selectedQuote
        guard !quote.isEmpty else { return nil }
        if selectedBook?.format == .pdf,
           let document = activePDFView?.document,
           let page = activePDFView?.currentSelection?.pages.first {
            let index = document.index(for: page)
            return IndexedPassage(locator: "pdf:\(index)", label: "Page \(index + 1)", text: quote)
        }
        if selectedTextRange.location != NSNotFound {
            return IndexedPassage(
                locator: "text:\(selectedTextRange.location):\(selectedTextRange.length)",
                label: selectedBook?.currentChapter ?? "Document",
                text: quote
            )
        }
        return nil
    }

    var aiContextPassage: IndexedPassage? {
        guard !aiContextQuote.isEmpty, !aiContextLocator.isEmpty else { return nil }
        return IndexedPassage(
            locator: aiContextLocator,
            label: aiContextLabel,
            text: aiContextQuote
        )
    }

    func currentReadingPassage() -> IndexedPassage? {
        guard let book = selectedBook else { return nil }
        if book.format == .pdf,
           let document = activePDFView?.document,
           let page = activePDFView?.currentPage,
           let text = page.string,
           !text.isEmpty {
            let pageIndex = document.index(for: page)
            return IndexedPassage(
                locator: "pdf:\(pageIndex)",
                label: "Page \(pageIndex + 1)",
                text: String(text.prefix(4_000))
            )
        }
        guard let text = extractedResearchText else { return nil }
        let value = text as NSString
        let offset = BookContentEntry(
            id: "current", title: "", locator: book.lastLocator, level: 0
        ).textOffset ?? 0
        let start = max(0, min(offset, value.length) - 300)
        let length = min(2_000, value.length - start)
        guard length > 0 else { return nil }
        return IndexedPassage(
            locator: "text:\(start):\(length)",
            label: book.currentChapter,
            text: value.substring(with: NSRange(location: start, length: length))
        )
    }

    var extractedResearchText: String? {
        switch loadedContent {
        case .attributedText(let value), .epub(let value, _): value.string
        default: nil
        }
    }

    func navigate(to citation: PassageCitation) {
        guard let book = selectedBook,
              citation.contentHash == researchContentHash else { return }
        destination = .reader
        locationNavigation = LocationNavigation(bookID: book.id, locator: citation.locator)
    }

    private func pdfPageIndex(from locator: String) -> Int? {
        let parts = locator.split(separator: ":")
        guard parts.count == 2, parts[0] == "pdf" else { return nil }
        return Int(parts[1])
    }
}

extension HighlightColor {
    var nsColor: NSColor {
        switch self {
        case .amber: NSColor(red: 0.88, green: 0.64, blue: 0.23, alpha: 1)
        case .sage: NSColor(red: 0.43, green: 0.52, blue: 0.40, alpha: 1)
        case .rose: NSColor(red: 0.67, green: 0.40, blue: 0.36, alpha: 1)
        }
    }

    var swiftUIColor: Color {
        Color(nsColor: nsColor)
    }
}
