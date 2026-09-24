# Leaf Native 1.2.0

AI reading assistance, built for researchers.

## Highlights

- **Ask AI About This** — select any passage in a PDF or text book, right-click → *Ask AI About This*, and chat with the book's context attached
- **Research companion pane** — share a resizable side pane with Notebook, keep multiple local conversations per book, and read streamed Markdown answers with links, lists, tables, and code blocks
- **Traceable answers** — retrieve text from the open document, prioritize a selected passage, and jump from numbered citations to the cited page or text position
- **Paper discovery** — search OpenAlex for related papers, confirm DOI bibliographic metadata with Crossref, and import downloaded PDFs for full-text analysis
- **One-tap actions** — summarize the current section, or generate review quiz questions from your highlights
- **Conversation controls** — stop, retry, or copy an answer; the reader remains usable beside the chat
- **Three providers** — pick in Settings → AI Assistant:
  - *Apple Intelligence* — free, private, on-device (macOS 26+)
  - *OpenAI API* — connect with an OpenAI Platform API key, choose a current model or enter a custom model ID
  - *ChatGPT account* — sign in with the Codex OAuth flow and use a ChatGPT subscription model. This route depends on Codex's private backend and may change.
- API keys and ChatGPT tokens are stored in the macOS Keychain. OpenAI API usage is billed separately from ChatGPT subscriptions.

## Downloads

- **DMG** — recommended installer; drag Leaf Native into Applications
- **ZIP** — portable app bundle
- **SHA256SUMS.txt** — checksums for both downloads

Leaf Native requires macOS 15 or later (macOS 26 for the on-device Apple Intelligence provider).

## First Launch (important)

This build is ad-hoc signed — not Apple-notarized yet — so **macOS Gatekeeper will block the first launch**. It only takes one step to fix:

1. Drag **Leaf Native** into **Applications**
2. Then **either**:
   - Right-click the app in Applications → **Open** → click **Open** again, **or**
   - Run in Terminal:

     ```
     xattr -dr com.apple.quarantine "/Applications/Leaf Native.app"
     ```

One-time fix — the app opens normally afterwards and updates itself via the app menu → **Check for Updates…** (the built-in updater strips quarantine for you on each update).
