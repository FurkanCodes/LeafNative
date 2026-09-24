import SwiftData
import SwiftUI

extension Notification.Name {
    static let leafOpenBook = Notification.Name("leaf.openBook")
    static let leafCheckUpdates = Notification.Name("leaf.checkUpdates")
    static let leafAskAI = Notification.Name("leaf.askAI")
    static let leafHighlight = Notification.Name("leaf.highlight")
    static let leafAddNote = Notification.Name("leaf.addNote")
    static let leafPreviousPage = Notification.Name("leaf.previousPage")
    static let leafNextPage = Notification.Name("leaf.nextPage")
    static let leafEditNote = Notification.Name("leaf.editNote")
    static let leafRemoveHighlight = Notification.Name("leaf.removeHighlight")
    static let leafExportNotes = Notification.Name("leaf.exportNotes")
    static let leafExportAllNotes = Notification.Name("leaf.exportAllNotes")
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
        .modelContainer(for: [
            BookRecord.self,
            AnnotationRecord.self,
            AIThreadRecord.self,
            AIChatMessageRecord.self,
        ])
        .defaultSize(width: 1440, height: 920)
        .windowToolbarStyle(.unified(showsTitle: false))
        .handlesExternalEvents(matching: [])
        .commands {
            LeafCommands()
        }

        Settings {
            SettingsView()
                .environment(store)
                .frame(width: 540, height: 480)
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

        CommandGroup(after: .importExport) {
            Button("Export Notes…") {
                NotificationCenter.default.post(name: .leafExportNotes, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("Export All Notes…") {
                NotificationCenter.default.post(name: .leafExportAllNotes, object: nil)
            }
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                NotificationCenter.default.post(
                    name: .leafCheckUpdates,
                    object: nil
                )
            }
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

            Button("Add Note") {
                NotificationCenter.default.post(name: .leafAddNote, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
