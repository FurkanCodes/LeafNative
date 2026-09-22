import SwiftData
import SwiftUI

struct AIChatView: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query private var annotations: [AnnotationRecord]
    @FocusState private var inputFocused: Bool

    private var bookHighlights: [AnnotationRecord] {
        guard let book = store.selectedBook else { return [] }
        return annotations.filter { $0.bookID == book.id }
    }

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            HStack {
                Label("Ask AI", systemImage: "sparkles")
                    .font(.headline)
                Text(store.aiProvider.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if store.aiStatus == .working {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding()

            if !store.aiContextQuote.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "quote.opening")
                        .foregroundStyle(.secondary)
                    Text(store.aiContextQuote)
                        .font(.caption)
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        store.aiContextQuote = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.aiMessages) { message in
                            AIMessageBubble(message: message)
                                .id(message.id)
                        }
                        if store.aiMessages.isEmpty {
                            ContentUnavailableView {
                                Label(
                                    "Nothing asked yet",
                                    systemImage: "bubble.left.and.text.bubble.right"
                                )
                            } description: {
                                Text(
                                    "Ask about what you're reading, "
                                        + "summarize the section, or quiz "
                                        + "yourself on highlights."
                                )
                            }
                            .padding(.top, 40)
                        }
                    }
                    .padding()
                }
                .onChange(of: store.aiMessages.count) {
                    if let last = store.aiMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Menu {
                    Button("Summarize this section") {
                        store.summarizeSection()
                    }
                    Button("Quiz me on my highlights") {
                        store.quizFromHighlights(
                            bookHighlights.map(\.quote)
                        )
                    }
                } label: {
                    Label("Actions", systemImage: "wand.and.stars")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                TextField(
                    "Ask about this book…",
                    text: $store.aiDraft,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { store.sendAIMessage() }

                Button {
                    store.sendAIMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(
                    store.aiDraft
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty || store.aiStatus == .working
                )
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 520)
        .onAppear { inputFocused = true }
    }
}

private struct AIMessageBubble: View {
    let message: AIMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role == .user ? "You" : "Leaf")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(message.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(10)
                .background(
                    message.role == .user
                        ? Color.accentColor.opacity(0.12)
                        : Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 10)
                )
        }
    }
}
