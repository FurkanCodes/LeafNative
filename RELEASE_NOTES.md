# Leaf Native 1.4.0

A notebook that works the way you study, notes that leave with you, and a research companion that finds the right passages.

## What's new

### Note-taking
- **⇧⌘N** highlights your selection and opens a note editor right under it. With nothing selected, it starts a note about the current page.
- Right-click any highlight in the book to **Add Note**, **Edit Note**, or **Remove Highlight** — in PDFs and text alike.
- The notebook now lists highlights and notes in reading order, with an **All | Notes** filter, a visible **Add note** on every highlight, and a **New Note** button. Notes save as you type; press **Done**, ⌘↩, or Esc to finish.
- Highlights whose position drifted are repaired automatically when a book opens.

### Export and citations
- **Export Notes as Markdown** (⇧⌘E) writes your highlights and notes with YAML front matter, an APA reference, chapter headings, and Pandoc citations like `[@key, p. 12]` — ready for Obsidian, Zettlr, or Pandoc.
- **Export All Notes** creates a Markdown file per book plus a shared `Leaf Library.bib`.
- **Copy APA Reference**, **Copy BibTeX**, and **Copy Quote with Citation**. Leaf finds a paper's DOI, confirms it matches the document, and looks it up on Crossref (or doi.org for arXiv and other registries). You can also set a DOI yourself.

### Research companion
- Passage retrieval understands meaning, not just matching words — "why do people follow the crowd?" now finds passages about conformity. It runs entirely on your Mac.
- Fixed PDFs where only one passage per page could reach the assistant; citations now name the section, e.g. "Page 12 · Methods".
- Paper results open their DOI pages, offer **Open paper**, **Copy citation**, and **Open PDF** when available, and show matching abstract terms.
- Answers use clearer headings and lists, and document citations and external sources sit in separate expandable sections.

## Downloads

- **DMG** — drag Leaf Native into Applications
- **ZIP** — portable app bundle
- **SHA256SUMS.txt** — checksums for both downloads

Leaf Native requires macOS 15 or later (macOS 26 for the on-device Apple Intelligence provider).

## First launch

This build is ad-hoc signed and is not Apple-notarized. If macOS blocks the first launch, right-click Leaf Native in Applications and choose **Open**, or run:

```
xattr -dr com.apple.quarantine "/Applications/Leaf Native.app"
```
