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

    var body: some View {
        Label(message, systemImage: "checkmark")
            .font(.caption)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .foregroundStyle(.white)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}
