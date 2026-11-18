import Foundation
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

    /// Directory for a part, verified to stay inside the root.
    func directory(forLibraryID id: String) throws -> URL {
        let dir = rootURL.appendingPathComponent(Self.sanitize(id), isDirectory: true).standardizedFileURL
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

    /// Loads every readable part; unreadable or incomplete directories are skipped.
    public func load() throws -> [LibraryPart] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootURL.path) else { return [] }
        let dirs = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])
        var parts: [LibraryPart] = []
        for dir in dirs where !dir.lastPathComponent.hasPrefix(".tmp-") {
            guard let json = try? Data(contentsOf: dir.appendingPathComponent("part.json")),
                  let meta = try? JSONDecoder().decode(Meta.self, from: json),
                  let graphic = try? Data(contentsOf: dir.appendingPathComponent(
                    Self.sanitize(meta.definition.graphicAsset)))
            else { continue }
            parts.append(LibraryPart(definition: meta.definition, graphic: graphic, source: meta.source))
        }
        return parts
    }

    /// Writes into a temp directory, then swaps it in (replacing an existing part of the same ID).
    public func write(_ part: LibraryPart) throws {
        let fm = FileManager.default
        let dest = try directory(forLibraryID: part.definition.libraryID)
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let tmp = rootURL.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: tmp) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let meta = Meta(definition: part.definition, source: part.source)
        try encoder.encode(meta).write(to: tmp.appendingPathComponent("part.json"), options: .atomic)
        try part.graphic.write(to: tmp.appendingPathComponent(Self.sanitize(part.definition.graphicAsset)),
                               options: .atomic)

        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
    }
}
