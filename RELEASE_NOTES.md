# Leaf Native 1.5.0

A calmer workspace: a notebook organized like the book, a sidebar that shows where you are, and highlighting right where you select.

## What's new

### Notebook
- Highlights and notes are **grouped by chapter or section**, with headers that stay in view and collapse, and a **"You're reading here"** marker at your place in the book.
- **Search** your highlights and notes, and **filter** by notes or by color.
- Quotes carry a wash of their highlight color, and each note sits in its own box beneath its quote, with Markdown formatting.
- Edit notes in place: **Return** saves, **Shift-Return** starts a new line, and **Esc** puts the note back as it was.
- Move through entries with **↑/↓**, press **Return** to edit and **Delete** to remove, then **Undo** from the confirmation if you change your mind.
- New highlights and notes scroll into view as you add them.
- Notebook and Ask AI now share a single header.

### Highlighting
- Select text and a bar appears above the first word with the three highlight colors, **Note**, and **Ask AI** — in PDFs and books alike.
- **Ask AI About Selection** is in the Reading menu (⇧⌘A).
- A leaner toolbar keeps the page in front.

### Sidebar
- A **Now Reading** card shows the open book and your progress.
- **Contents** marks the sections you've read and the one you're in, with a count of highlights and notes in each.

## Fixes
- Leaf now reopens a book exactly where you left off. Previously the saved place slipped back a little each time, and the current section could be wrong.
- PDF highlights keep their light tint after reopening instead of coming back at full strength. Existing highlights are shown with the lighter tint too.
- Section titles typeset in capitals read naturally ("Make a Place for Return").
- The reader footer names the section you're in.

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
