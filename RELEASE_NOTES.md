# Leaf Native 1.1.0

The second release of Leaf Native: in-app auto-updates, a proper EPUB reader core, and polish across the library.

## Highlights

- **Auto-update** — Leaf now checks GitHub Releases on launch and from the app menu; download and install updates without leaving the app (Settings → Software Update)
- **Real EPUB support** — chapters follow the spine's reading order and the sidebar shows the book's own table of contents (nav/NCX)
- **Resume where you left off** — reading position and page now persist for every format, not just PDFs
- **Position bookmarks** — bookmark a spot and jump back to it from the reader toolbar
- **Faster loading** — large books parse off the main thread, no more UI freezes
- **Finder "Open With"** — open books in Leaf directly from Finder
- **Library sorting** — sort by Last Opened, Title, or Author; appearance and sort choices now persist across launches
- **Safer highlights** — PDF edits are written atomically so a crash can't corrupt a book

## Downloads

- **DMG** — recommended installer; drag Leaf Native into Applications
- **ZIP** — portable app bundle
- **SHA256SUMS.txt** — checksums for both downloads

Leaf Native requires macOS 15 or later. This build is ad-hoc signed but not yet Apple-notarized; on first launch, right-click the app and choose **Open** if Gatekeeper asks.
