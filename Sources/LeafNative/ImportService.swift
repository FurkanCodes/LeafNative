import AppKit
import CryptoKit
import Foundation
import PDFKit

enum ImportError: LocalizedError {
    case unableToAccess
    case unableToCreateLibrary

    var errorDescription: String? {
        switch self {
        case .unableToAccess:
            "Leaf could not access this file."
        case .unableToCreateLibrary:
            "Leaf could not create its local library."
        }
    }
}

struct ImportedBook {
    let title: String
    let author: String
    let format: ReaderFormat
    let localURL: URL
    let chapter: String
    let contentHash: String
}

@MainActor
enum ImportService {
    static func importBook(from sourceURL: URL) throws -> ImportedBook {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ImportError.unableToCreateLibrary
        }

        let library = applicationSupport
            .appendingPathComponent("Leaf", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        try fileManager.createDirectory(
            at: library,
            withIntermediateDirectories: true
        )

        let format = ReaderFormat(url: sourceURL)
        let contentHash = (try? Self.sha256Hex(of: sourceURL)) ?? ""
        let destination = library
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension)
        try fileManager.copyItem(at: sourceURL, to: destination)

        var title = sourceURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        var author = "Local publication"

        if format == .pdf, let document = PDFDocument(url: destination) {
            if let metadataTitle = document.documentAttributes?[
                PDFDocumentAttribute.titleAttribute
            ] as? String, !metadataTitle.isEmpty {
                title = metadataTitle
            }
            if let metadataAuthor = document.documentAttributes?[
                PDFDocumentAttribute.authorAttribute
            ] as? String, !metadataAuthor.isEmpty {
                author = metadataAuthor
            }
        }

        return ImportedBook(
            title: title,
            author: author,
            format: format,
            localURL: destination,
            chapter: format == .pdf ? "Page 1" : "Start reading",
            contentHash: contentHash
        )
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
