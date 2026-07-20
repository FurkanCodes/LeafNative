<p align="center">
  <img src="docs/app-icon.png" width="144" alt="Leaf Native app icon">
</p>

<h1 align="center">Leaf Native</h1>

<p align="center">
  A calm, genuinely native macOS reader for deep reading, highlights, and notes.
</p>

<p align="center">
  <a href="https://github.com/FurkanCodes/LeafNative/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/FurkanCodes/LeafNative?style=flat-square&color=57705a"></a>
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-2f3437?style=flat-square&logo=apple">
  <img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-f05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="Native SwiftUI and AppKit" src="https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-55705a?style=flat-square">
</p>

<p align="center">
  <a href="https://github.com/FurkanCodes/LeafNative/releases/latest"><strong>Download for macOS</strong></a>
</p>

![Leaf Native reading view with library, contents, and notebook](docs/leaf-native-preview.jpg)

Leaf keeps the book at the center. Its three-pane workspace gives the library, reader, and notebook equal dignity, while every pane can get out of the way when you want to focus.

## Why Leaf

- **Native by design** — SwiftUI, AppKit, PDFKit, and SwiftData; no Electron, WebView, or browser shell.
- **A notebook beside the page** — collect highlights and notes without breaking your reading flow.
- **Fast, deliberate highlighting** — select text, choose Amber, Sage, or Rose, and keep reading.
- **Highlights that lead somewhere** — click a saved highlight to jump directly back to its passage.
- **Real PDF annotations** — PDF highlights are written into the document and can be removed from Leaf.
- **Useful contents navigation** — EPUB structure and PDF outlines become a navigable table of contents.
- **Local-first library** — books, progress, bookmarks, highlights, and notes stay on your Mac.
- **Made for macOS** — system menus, keyboard shortcuts, contextual actions, materials, and accessibility.

## Supported formats

| Experience | Formats |
| --- | --- |
| Built-in reader | PDF, EPUB, TXT, Markdown, HTML, RTF/RTFD, FB2, DOCX, CBZ |
| Text extraction | MOBI, AZW, AZW3 (common unencrypted PalmDOC variants) |
| System preview fallback | CBR, DOC, and uncommon document variants |

DRM-protected Kindle and EPUB files require authorization from their vendor and are not supported.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Import a book | `⌘O` |
| Find in book | `⌘F` |
| Highlight selection | `⇧⌘H` |
| Highlight with a note | `⇧⌘N` |
| Previous / next page | `←` / `→` |

## Install

1. Download the latest DMG from [Releases](https://github.com/FurkanCodes/LeafNative/releases/latest).
2. Open it and drag **Leaf Native** into **Applications**.
3. On first launch, right-click the app and choose **Open** if macOS shows a Gatekeeper warning.

The downloadable build is ad-hoc signed for this first public release. It is not yet Developer ID signed or notarized.

## Build from source

Leaf requires macOS 15 or later and Xcode 26, or another compatible Swift 6.2 toolchain.

```bash
git clone https://github.com/FurkanCodes/LeafNative.git
cd LeafNative
swift build
swift run Leaf
```

To create a signed local app bundle:

```bash
./scripts/build-app.sh
open "dist/Leaf Native.app"
```

To create the DMG and ZIP used for a release:

```bash
./scripts/build-release.sh 1.0.0
```

## Native architecture

| Layer | Technology |
| --- | --- |
| App shell and navigation | SwiftUI |
| Selectable reflowable text | AppKit `NSTextView` |
| PDF rendering and annotations | PDFKit |
| Library and reading state | SwiftData |
| Container formats | ZIPFoundation |
| System document fallback | Quick Look |

ZIPFoundation is the project's only third-party package dependency. It is used to unpack EPUB, DOCX, and CBZ containers.

## Privacy

Leaf has no account, analytics, advertising, or cloud backend. Imported books and reading data are stored locally on your Mac.

## License

This repository does not currently include an open-source license.

