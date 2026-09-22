# Leaf Native 1.2.0

AI reading assistance, built for researchers.

## Highlights

- **Ask AI About This** — select any passage in a PDF or text book, right-click → *Ask AI About This*, and chat with the book's context attached
- **AI panel** — a sparkles button in the reader toolbar opens a chat that knows which book, chapter, and passage you're on
- **One-tap actions** — summarize the current section, or generate review quiz questions from your highlights
- **Three providers** — pick in Settings → AI Assistant:
  - *Apple Intelligence* — free, private, on-device (macOS 26+)
  - *OpenAI API key* — bring your own key (stored in Keychain), pick any model
  - *ChatGPT account* — experimental sign-in using your ChatGPT subscription. Relies on undocumented OpenAI internals and may stop working — if it breaks, the other providers still work
- Your API key and sign-in tokens live in the macOS Keychain, never in files

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
