import SwiftUI

enum LeafPalette {
    static let amber = Color(red: 0.75, green: 0.49, blue: 0.12)
    static let amberSoft = Color(red: 0.92, green: 0.74, blue: 0.40)
    static let sage = Color(red: 0.38, green: 0.48, blue: 0.36)
    static let rose = Color(red: 0.62, green: 0.35, blue: 0.31)
    // Reading themes are explicit user choices. Paper intentionally stays light
    // when the surrounding macOS chrome uses Dark Mode.
    static let paper = Color(
        nsColor: NSColor(red: 0.985, green: 0.978, blue: 0.958, alpha: 1)
    )
    static let sepia = Color(red: 0.95, green: 0.90, blue: 0.80)
    static let night = Color(red: 0.085, green: 0.09, blue: 0.083)

    /// Amber dark enough for small text on light chrome, soft in Dark Mode.
    static let amberText = adaptive(
        light: NSColor(red: 0.56, green: 0.36, blue: 0.05, alpha: 1),
        dark: NSColor(red: 0.92, green: 0.74, blue: 0.40, alpha: 1)
    )
    /// Amber for small marks (dots, progress) in either appearance.
    static let amberMark = adaptive(
        light: NSColor(red: 0.75, green: 0.49, blue: 0.12, alpha: 1),
        dark: NSColor(red: 0.92, green: 0.74, blue: 0.40, alpha: 1)
    )

    /// The notebook's ground; solid so pinned section headers match it.
    static let notebook = adaptive(
        light: NSColor(red: 0.957, green: 0.953, blue: 0.941, alpha: 1),
        dark: NSColor(red: 0.149, green: 0.145, blue: 0.137, alpha: 1)
    )

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension HighlightColor {
    /// The translucent marker behind a quote in the notebook, echoing the page.
    var wash: Color {
        switch self {
        case .amber:
            LeafPalette.adaptive(
                light: NSColor(red: 0.92, green: 0.74, blue: 0.40, alpha: 0.45),
                dark: NSColor(red: 0.92, green: 0.74, blue: 0.40, alpha: 0.27)
            )
        case .sage:
            LeafPalette.adaptive(
                light: NSColor(red: 0.47, green: 0.59, blue: 0.44, alpha: 0.28),
                dark: NSColor(red: 0.59, green: 0.73, blue: 0.55, alpha: 0.25)
            )
        case .rose:
            LeafPalette.adaptive(
                light: NSColor(red: 0.75, green: 0.43, blue: 0.38, alpha: 0.25),
                dark: NSColor(red: 0.86, green: 0.55, blue: 0.49, alpha: 0.25)
            )
        }
    }
}

enum SectionTitle {
    private static let minorWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "in", "nor",
        "of", "on", "or", "the", "to", "with",
    ]

    /// Headings typeset in capitals ("THE INTERVAL BEFORE JUDGMENT") read as
    /// title case in navigation; mixed-case titles are left as written.
    static func display(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: \.isLetter), trimmed == trimmed.uppercased() else {
            return trimmed
        }
        let words = trimmed.lowercased().split(separator: " ", omittingEmptySubsequences: true)
        return words.enumerated().map { index, word in
            let isEdge = index == 0 || index == words.count - 1
            if !isEdge, minorWords.contains(String(word)) { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        .joined(separator: " ")
    }
}

extension ReaderStore.ReaderTheme {
    var background: Color {
        switch self {
        case .paper: LeafPalette.paper
        case .sepia: LeafPalette.sepia
        case .night: LeafPalette.night
        }
    }

    var foreground: Color {
        switch self {
        case .night: Color(red: 0.90, green: 0.88, blue: 0.84)
        default: Color(red: 0.15, green: 0.14, blue: 0.12)
        }
    }

    var nsBackground: NSColor {
        NSColor(background)
    }

    var nsForeground: NSColor {
        NSColor(foreground)
    }
}

struct ToastView: View {
    let message: String
    var undo: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Label(message, systemImage: "checkmark")
            if let undo {
                Button("Undo", action: undo)
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(LeafPalette.amberSoft)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .foregroundStyle(.white)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}
