import Foundation
import SwiftData

struct PassageCitation: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var locator: String
    var quote: String
    var label: String
    var contentHash: String
}

enum ResearchCitationLinks {
    static func linkify(_ text: String, citations: [PassageCitation]) -> String {
        citations.reduce(text) { output, citation in
            output.replacingOccurrences(
                of: "[\(citation.id)]",
                with: "[\(citation.id.dropFirst())](leaf-citation://\(citation.id))"
            )
        }
    }
}

struct PaperResult: Codable, Identifiable, Equatable, Sendable {
    var id: String { doi }
    var doi: String
    var title: String
    var authors: String
    var year: Int?
    var landingURL: URL
    var metadataVerified: Bool
}

@Model
final class AIThreadRecord {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), bookID: UUID, title: String = "New conversation") {
        self.id = id
        self.bookID = bookID
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
    }
}

@Model
final class AIChatMessageRecord {
    @Attribute(.unique) var id: UUID
    var threadID: UUID
    var roleRaw: String
    var text: String
    var createdAt: Date
    var providerRaw: String
    var modelID: String
    var contentHash: String
    var citationsData: Data
    var papersData: Data
    var errorText: String

    init(
        id: UUID = UUID(),
        threadID: UUID,
        role: String,
        text: String,
        providerRaw: String = "",
        modelID: String = "",
        contentHash: String = ""
    ) {
        self.id = id
        self.threadID = threadID
        self.roleRaw = role
        self.text = text
        self.createdAt = .now
        self.providerRaw = providerRaw
        self.modelID = modelID
        self.contentHash = contentHash
        self.citationsData = Data()
        self.papersData = Data()
        self.errorText = ""
    }

    var citations: [PassageCitation] {
        get { (try? JSONDecoder().decode([PassageCitation].self, from: citationsData)) ?? [] }
        set { citationsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var papers: [PaperResult] {
        get { (try? JSONDecoder().decode([PaperResult].self, from: papersData)) ?? [] }
        set { papersData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}
