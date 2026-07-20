import SwiftData
import SwiftUI

extension Notification.Name {
    static let leafOpenBook = Notification.Name("leaf.openBook")
    static let leafHighlight = Notification.Name("leaf.highlight")
    static let leafAddNote = Notification.Name("leaf.addNote")
    static let leafPreviousPage = Notification.Name("leaf.previousPage")
    static let leafNextPage = Notification.Name("leaf.nextPage")
}

@main
struct LeafNativeApp: App {
    @State private var store = ReaderStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .frame(minWidth: 920, minHeight: 680)
        }
        .modelContainer(for: [BookRecord.self, AnnotationRecord.self])
        .defaultSize(width: 1440, height: 920)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            LeafCommands()
        }

        Settings {
            SettingsView()
                .environment(store)
                .frame(width: 480, height: 320)
        }
    }
}

struct LeafCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Book…") {
                NotificationCenter.default.post(name: .leafOpenBook, object: nil)
            }
            .keyboardShortcut("o")
        }

        CommandMenu("Reading") {
            Button("Previous Page") {
                NotificationCenter.default.post(name: .leafPreviousPage, object: nil)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button("Next Page") {
                NotificationCenter.default.post(name: .leafNextPage, object: nil)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Divider()

            Button("Highlight Selection") {
                NotificationCenter.default.post(
                    name: .leafHighlight,
                    object: HighlightColor.amber
                )
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button("Add Note to Selection") {
                NotificationCenter.default.post(name: .leafAddNote, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
