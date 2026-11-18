import Foundation
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

    public init(bundledCatalogURL: URL, personalStore: PersonalLibraryStore) {
        self.bundledCatalogURL = bundledCatalogURL
        self.personalStore = personalStore
    }

    /// All parts, personal overriding bundled by `libraryID`, sorted by title.
    public func allParts() async -> [LibraryPart] {
        var byID: [String: LibraryPart] = [:]
        for part in loadBundled() { byID[part.definition.libraryID] = part }
        for part in (try? personalStore.load()) ?? [] { byID[part.definition.libraryID] = part }
        return sortedByTitle(Array(byID.values))
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
        await allParts().first { $0.definition.libraryID == libraryID }
    }

    /// Imports a Fritzing `.fzpz` and stores it as a personal part (re-import replaces).
    public func importFzpz(_ data: Data) async throws -> LibraryPart {
        let (definition, graphic) = try FzpzImporter.importPart(data)
        let part = LibraryPart(definition: definition, graphic: graphic, source: .personal)
        try personalStore.write(part)
        return part
    }

    public func save(_ part: LibraryPart) async throws {
        var stored = part
        stored.source = .personal
        try personalStore.write(stored)
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
