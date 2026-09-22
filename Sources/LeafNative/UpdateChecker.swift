import AppKit
import Foundation

struct GitHubRelease: Sendable {
    let tag: String
    let version: String
    let title: String
    let notes: String
    let htmlURL: URL
    let zipAssetURL: URL?
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available
    case downloading
    case installing
}

enum UpdateError: LocalizedError {
    case checkFailed
    case noReleaseAsset
    case installFailed

    var errorDescription: String? {
        switch self {
        case .checkFailed:
            "Leaf could not reach GitHub to check for updates."
        case .noReleaseAsset:
            "The latest release has no downloadable app archive."
        case .installFailed:
            "Leaf downloaded the update but could not install it."
        }
    }
}

@MainActor
enum UpdateChecker {
    static var currentVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
    }

    static func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(
            url: URL(
                string: "https://api.github.com/repos/FurkanCodes/LeafNative/releases/latest"
            )!
        )
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.checkFailed
        }

        let json = try JSONDecoder().decode(ReleaseJSON.self, from: data)
        let zipAsset = json.assets.first {
            $0.name.hasSuffix("-macOS.zip")
        } ?? json.assets.first { $0.name.hasSuffix(".zip") }

        return GitHubRelease(
            tag: json.tagName,
            version: String(
                json.tagName.drop(while: { $0 == "v" || $0 == "V" })
            ),
            title: json.name ?? json.tagName,
            notes: json.body ?? "",
            htmlURL: json.htmlURL,
            zipAssetURL: zipAsset?.browserDownloadURL
        )
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func components(of version: String) -> [Int] {
            version
                .drop(while: { $0 == "v" || $0 == "V" })
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = components(of: candidate)
        let b = components(of: current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func downloadAndInstall(_ release: GitHubRelease) async throws {
        guard let assetURL = release.zipAssetURL else {
            throw UpdateError.noReleaseAsset
        }
        let (downloadedURL, _) = try await URLSession.shared.download(
            from: assetURL
        )

        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory
            .appendingPathComponent(
                "LeafUpdate-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )

        try await run(
            "/usr/bin/ditto",
            ["-x", "-k", downloadedURL.path, workDir.path]
        )

        guard let newApp = try fileManager.contentsOfDirectory(
            at: workDir,
            includingPropertiesForKeys: nil
        ).first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.installFailed
        }

        let destination = installedAppURL()
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: newApp)
        } else {
            _ = try fileManager.copyItem(at: newApp, to: destination)
        }

        // Ad-hoc-signed builds carry the quarantine bit through ditto;
        // the running copy was already user-approved, so drop it.
        try? await run(
            "/usr/bin/xattr",
            ["-dr", "com.apple.quarantine", destination.path]
        )

        try await NSWorkspace.shared.openApplication(
            at: destination,
            configuration: NSWorkspace.OpenConfiguration()
        )
        NSApp.terminate(nil)
    }

    private static func installedAppURL() -> URL {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            return URL(fileURLWithPath: bundlePath)
        }
        return URL(fileURLWithPath: "/Applications")
            .appendingPathComponent("Leaf Native.app")
    }

    private static func run(
        _ executable: String,
        _ arguments: [String]
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.installFailed)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private struct ReleaseJSON: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case assets
        }
    }
}
