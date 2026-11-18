import Foundation
import os
import SketchCore

private struct CatalogRow: Decodable {
    var id: String
    var file: String
}

/// Bundled catalog merged with the user's personal parts (personal wins by `libraryID`).
public actor PartsLibrary {
    private let bundledCatalogURL: URL
    private let personalStore: PersonalLibraryStore
    private var bundled: [LibraryPart]?
    private var personalIndex: [String: LibraryPart]?
    private var merged: [LibraryPart]?
    private let logger = Logger(subsystem: "com.flyingturtle.flyingsketch", category: "parts")

    /// Problems found by the most recent personal-library load.
    public private(set) var lastLoadIssues: [LoadIssue] = []

    public init(bundledCatalogURL: URL, personalStore: PersonalLibraryStore) {
        self.bundledCatalogURL = bundledCatalogURL
        self.personalStore = personalStore
    }

    /// All parts, personal overriding bundled by `libraryID`, sorted by title.
    public func allParts() async -> [LibraryPart] {
        if let merged { return merged }
        var byID: [String: LibraryPart] = [:]
        for part in loadBundled() { byID[part.definition.libraryID] = part }
        for (id, part) in loadPersonal() { byID[id] = part }
        let result = sortedByTitle(Array(byID.values))
        merged = result
        return result
    }

    /// Drops caches so the next read re-scans disk (e.g. after iCloud delivers new parts).
    public func reload() {
        personalIndex = nil
        merged = nil
    }

    /// Case- and diacritic-insensitive; every whitespace-separated token must match title, family, a tag or a property value.
    public func search(_ query: String) async -> [LibraryPart] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
        let all = await allParts()
        guard !tokens.isEmpty else { return all }
        return all.filter { part in
            let d = part.definition
            let haystack = ([d.title, d.family] + d.tags + Array(d.properties.values)).map(Self.fold)
            return tokens.allSatisfy { token in haystack.contains { $0.contains(token) } }
        }
    }

    public func part(libraryID: String) async -> LibraryPart? {
        if let p = loadPersonal()[libraryID] { return p }
        return loadBundled().first { $0.definition.libraryID == libraryID }
    }

    /// Imports a Fritzing `.fzpz` and stores it as a personal part (re-import replaces).
    public func importFzpz(_ data: Data) async throws -> LibraryPart {
        let (definition, graphic) = try FzpzImporter.importPart(data)
        let part = LibraryPart(definition: definition, graphic: graphic, source: .personal)
        try personalStore.write(part)
        reload()
        return part
    }

    public func save(_ part: LibraryPart) async throws {
        try await save(part, studio: nil)
    }

    public func save(_ part: LibraryPart, studio: [String: Data]?) async throws {
        var stored = part
        stored.source = .personal
        try personalStore.write(stored, studio: studio)
        reload()
    }

    public func studioFiles(libraryID: String) async throws -> [String: Data]? {
        try personalStore.studioFiles(forLibraryID: libraryID)
    }

    /// Deletes a personal part; ids not in the personal index (incl. bundled) throw `notPersonal`.
    public func delete(libraryID: String) async throws {
        guard loadPersonal()[libraryID] != nil else { throw PersonalLibraryError.notPersonal(libraryID) }
        try personalStore.delete(libraryID: libraryID)
        reload()
    }

    private func loadPersonal() -> [String: LibraryPart] {
        if let personalIndex { return personalIndex }
        var index: [String: LibraryPart] = [:]
        do {
            let result = try personalStore.load()
            for part in result.parts { index[part.definition.libraryID] = part }
            lastLoadIssues = result.issues
        } catch {
            logger.error("personal library root unreadable: \(String(describing: error), privacy: .public)")
            lastLoadIssues = [LoadIssue(directory: personalStore.rootURL, reason: .rootUnreadable)]
        }
        for issue in lastLoadIssues {
            logger.error("part load issue \(issue.reason.rawValue, privacy: .public): \(issue.directory.lastPathComponent, privacy: .public)")
        }
        personalIndex = index
        return index
    }

    private func loadBundled() -> [LibraryPart] {
        if let bundled { return bundled }
        let loaded = Self.readBundled(at: bundledCatalogURL)
        bundled = loaded
        return loaded
    }

    private static func readBundled(at root: URL) -> [LibraryPart] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("catalog.json")),
              let rows = try? JSONDecoder().decode([CatalogRow].self, from: data) else { return [] }
        return rows.compactMap { row in
            guard let json = try? Data(contentsOf: root.appendingPathComponent(row.file)),
                  let def = try? JSONDecoder().decode(PartDefinition.self, from: json),
                  let graphic = try? Data(contentsOf: root.appendingPathComponent("graphics/\(def.graphicAsset)"))
            else { return nil }
            return LibraryPart(definition: def, graphic: graphic, source: .bundled)
        }
    }

    private func sortedByTitle(_ parts: [LibraryPart]) -> [LibraryPart] {
        parts.sorted {
            let c = $0.definition.title.localizedCaseInsensitiveCompare($1.definition.title)
            return c == .orderedSame ? $0.definition.libraryID < $1.definition.libraryID : c == .orderedAscending
        }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
