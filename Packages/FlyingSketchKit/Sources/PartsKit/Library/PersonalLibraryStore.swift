import Foundation
import CryptoKit
import SketchCore

/// A part in the library: definition + graphic bytes + where it came from.
public struct LibraryPart: Hashable, Sendable {
    public enum Source: String, Codable, Hashable, Sendable { case bundled, personal }

    public var definition: PartDefinition
    public var graphic: Data
    public var source: Source

    public init(definition: PartDefinition, graphic: Data, source: Source) {
        self.definition = definition
        self.graphic = graphic
        self.source = source
    }
}

public enum PersonalLibraryError: Error, Equatable {
    case escapesRoot(String)
}

/// A per-part problem found while loading; the rest of the library still loads.
public struct LoadIssue: Hashable, Sendable {
    /// `invalidDefinition`: decoded, but fails `PartDefinition` validation (e.g. unsafe graphic asset name).
    public enum Reason: String, Sendable { case unreadableMetadata, invalidDefinition, missingGraphic, notDownloaded, rootUnreadable }
    public var directory: URL
    public var reason: Reason
}

/// On-disk personal parts: one directory per sanitized `libraryID` holding `part.json` + the graphic.
public struct PersonalLibraryStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) { self.rootURL = rootURL }

    /// iCloud container `Documents/Parts` if available, else `Application Support/FlyingSketch/Parts`.
    /// `url(forUbiquityContainerIdentifier:)` must not run on the main thread, hence `@concurrent`.
    @concurrent public static func defaultRoot() async -> URL {
        let fm = FileManager.default
        if let container = fm.url(forUbiquityContainerIdentifier: "iCloud.com.flyingturtle.flyingsketch") {
            let dir = container.appendingPathComponent("Documents/Parts", isDirectory: true)
            if (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil { return dir }
        }
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("FlyingSketch/Parts", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Replace anything outside `[A-Za-z0-9._-]` with `_`; empty / `.` / `..` get a `part_` prefix.
    static func sanitize(_ id: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let s = String(id.map { allowed.contains($0) ? $0 : "_" })
        return (s.isEmpty || s == "." || s == "..") ? "part_" + s : s
    }

    /// `<sanitized prefix (64)>-<12 hex of SHA-256(raw id)>`: distinct IDs never share a directory.
    static func directoryName(forLibraryID id: String) -> String {
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
        return String(sanitize(id).prefix(64)) + "-" + hash
    }

    static func graphicFileName(_ kind: GraphicKind) -> String { "graphic." + kind.rawValue }

    /// Directory for a part, verified to stay inside the root.
    func directory(forLibraryID id: String) throws -> URL {
        let dir = rootURL.appendingPathComponent(Self.directoryName(forLibraryID: id), isDirectory: true)
            .standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path
        guard dir.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw PersonalLibraryError.escapesRoot(id)
        }
        return dir
    }

    private struct Meta: Codable {
        var definition: PartDefinition
        var source: LibraryPart.Source
    }

    /// Legacy atomic-write temp directories (`.tmp-<UUID>`) are not parts.
    private static func isLegacyTemp(_ name: String) -> Bool {
        name.hasPrefix(".tmp-") && UUID(uuidString: String(name.dropFirst(5))) != nil
    }

    /// Placeholder for a not-yet-downloaded iCloud file: `.<name>.icloud`. Starts the download if present.
    private static func requestDownloadIfPlaceholder(_ file: URL) -> Bool {
        let placeholder = file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + ".icloud")
        guard FileManager.default.fileExists(atPath: placeholder.path) else { return false }
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        return true
    }

    /// Loads every readable part; per-part problems are reported as issues, a root-level failure throws.
    public func load() throws -> (parts: [LibraryPart], issues: [LoadIssue]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootURL.path) else { return ([], []) }
        let dirs = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])
        var parts: [LibraryPart] = []
        var issues: [LoadIssue] = []
        for dir in dirs where !Self.isLegacyTemp(dir.lastPathComponent) {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let metaURL = dir.appendingPathComponent("part.json")
            if Self.requestDownloadIfPlaceholder(metaURL) {
                issues.append(LoadIssue(directory: dir, reason: .notDownloaded)); continue
            }
            guard let json = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(Meta.self, from: json) else {
                issues.append(LoadIssue(directory: dir, reason: .unreadableMetadata)); continue
            }
            guard isSafeAssetName(meta.definition.graphicAsset) else {
                issues.append(LoadIssue(directory: dir, reason: .invalidDefinition)); continue
            }
            let graphicURL = dir.appendingPathComponent(Self.graphicFileName(meta.definition.graphicKind))
            if Self.requestDownloadIfPlaceholder(graphicURL) {
                issues.append(LoadIssue(directory: dir, reason: .notDownloaded)); continue
            }
            guard let graphic = try? Data(contentsOf: graphicURL) else {
                issues.append(LoadIssue(directory: dir, reason: .missingGraphic)); continue
            }
            parts.append(LibraryPart(definition: meta.definition, graphic: graphic, source: meta.source))
        }
        return (parts, issues)
    }

    /// Writes into a temp directory (outside the synced root), then swaps it in; replaces the same ID.
    public func write(_ part: LibraryPart) throws {
        let fm = FileManager.default
        let dest = try directory(forLibraryID: part.definition.libraryID)
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let scratch = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest, create: true))
            ?? fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tmp = scratch.appendingPathComponent("part", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let meta = Meta(definition: part.definition, source: part.source)
        try encoder.encode(meta).write(to: tmp.appendingPathComponent("part.json"), options: .atomic)
        try part.graphic.write(to: tmp.appendingPathComponent(Self.graphicFileName(part.definition.graphicKind)),
                               options: .atomic)

        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
    }
}
