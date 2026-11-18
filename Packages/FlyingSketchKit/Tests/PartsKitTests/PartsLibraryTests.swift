import Foundation
import Testing
import SketchCore
@testable import PartsKit

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let catalogURL = repoRoot.appendingPathComponent("App/Catalog")

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("PartsLibraryTests-\(UUID().uuidString)")
}

private func fzpz() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/fritzing/AdafruitAHT20.fzpz", withExtension: nil))
    return try Data(contentsOf: url)
}

private func makePart(id: String, title: String = "Mine", family: String = "custom") -> LibraryPart {
    let def = PartDefinition(libraryID: id, versionHash: "h1", title: title, family: family, size: Vec2(x: 5, y: 5),
                             graphicAsset: "g.svg", graphicKind: .svg)
    return LibraryPart(definition: def, graphic: Data("<svg/>".utf8), source: .personal)
}

@Suite struct PartsLibraryTests {
    @Test func searchMatchesTitleFamilyTags() async throws {
        let store = PersonalLibraryStore(rootURL: tempRoot())
        let lib = PartsLibrary(bundledCatalogURL: catalogURL, personalStore: store)
        let all = await lib.allParts()
        #expect(all.count >= 13)
        #expect(await lib.search("").count == all.count)

        let byTitle = await lib.search("BREADBOARD")
        #expect(byTitle.count >= 2)
        #expect(byTitle.allSatisfy { $0.source == .bundled })
        // sorted by title
        let titles = byTitle.map(\.definition.title)
        #expect(titles == titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })

        let sensors = await lib.search("sensors")
        #expect(sensors.contains { $0.definition.family.lowercased() == "sensors" })

        let withTag = try #require(all.first { !$0.definition.tags.isEmpty })
        let tag = try #require(withTag.definition.tags.first)
        #expect(await lib.search(tag.uppercased()).contains { $0.definition.libraryID == withTag.definition.libraryID })

        // AND semantics + no match
        #expect(await lib.search("breadboard zzzznomatch").isEmpty)
        #expect(await lib.search("half breadboard").count >= 1)
    }

    @Test func searchIsDiacriticInsensitiveAndMatchesProperties() async throws {
        let store = PersonalLibraryStore(rootURL: tempRoot())
        var p = makePart(id: "cafe", title: "Café Sensor")
        p.definition.properties = ["voltage": "3V3"]
        try store.write(p)
        let lib = PartsLibrary(bundledCatalogURL: catalogURL, personalStore: store)
        #expect(await lib.search("cafe").map(\.definition.libraryID) == ["cafe"])
        #expect(await lib.search("CAFÉ 3v3").map(\.definition.libraryID) == ["cafe"])
    }

    @Test func personalOverridesBundledByLibraryID() async throws {
        let store = PersonalLibraryStore(rootURL: tempRoot())
        let lib = PartsLibrary(bundledCatalogURL: catalogURL, personalStore: store)
        let bundled = try #require(await lib.allParts().first)
        #expect(bundled.source == .bundled)
        let id = bundled.definition.libraryID

        var mine = makePart(id: id, title: "My override")
        mine.definition.graphicAsset = "x.svg"
        try await lib.save(mine)
        let got = try #require(await lib.part(libraryID: id))
        #expect(got.source == .personal)
        #expect(got.definition.title == "My override")
        let count = await lib.allParts().filter { $0.definition.libraryID == id }.count
        #expect(count == 1)
    }

    @Test func importFzpzPersists() async throws {
        let root = tempRoot()
        let lib = PartsLibrary(bundledCatalogURL: catalogURL, personalStore: PersonalLibraryStore(rootURL: root))
        let imported = try await lib.importFzpz(fzpz())
        #expect(imported.source == .personal)

        let reloaded = try PersonalLibraryStore(rootURL: root).load().parts
        let got = try #require(reloaded.first { $0.definition.libraryID == imported.definition.libraryID })
        #expect(got.definition == imported.definition)
        #expect(got.graphic == imported.graphic)

        // re-import replaces, no duplicate
        _ = try await lib.importFzpz(fzpz())
        #expect(try PersonalLibraryStore(rootURL: root).load().parts.count == 1)
        let fresh = PartsLibrary(bundledCatalogURL: catalogURL, personalStore: PersonalLibraryStore(rootURL: root))
        #expect(await fresh.part(libraryID: imported.definition.libraryID) != nil)
    }

    @Test func storeSanitizesIDs() throws {
        let root = tempRoot()
        let store = PersonalLibraryStore(rootURL: root)
        for id in ["../x", "a/b/../../c", "..", ".", "", "/abs/path"] {
            try store.write(makePart(id: id))
            let dir = try store.directory(forLibraryID: id)
            #expect(dir.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
            #expect(dir.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        }
        #expect(PersonalLibraryStore.sanitize("../x") == ".._x")
        #expect(!PersonalLibraryStore.directoryName(forLibraryID: "../x").contains("/"))
        #expect(PersonalLibraryStore.sanitize("..") == "part_..")
        #expect(PersonalLibraryStore.sanitize("") == "part_")
        let escaped = root.deletingLastPathComponent().appendingPathComponent("x")
        #expect(!FileManager.default.fileExists(atPath: escaped.appendingPathComponent("part.json").path))
        #expect(try store.load().parts.count == 6)
    }

    @Test func collidingSanitizedIDsSurviveReload() throws {
        let root = tempRoot()
        let store = PersonalLibraryStore(rootURL: root)
        let ids = ["a/b", "a_b", "a b", "é", "è", ".tmp-foo"]
        for id in ids { try store.write(makePart(id: id, title: id)) }
        let loaded = try store.load()
        #expect(loaded.issues.isEmpty)
        #expect(Set(loaded.parts.map(\.definition.libraryID)) == Set(ids))
    }

    @Test func graphicNamedPartJSONDoesNotClobberMetadata() throws {
        let store = PersonalLibraryStore(rootURL: tempRoot())
        var p = makePart(id: "evil")
        p.definition.graphicAsset = "part.json"
        try store.write(p)
        let loaded = try store.load()
        let got = try #require(loaded.parts.first)
        #expect(got.definition.graphicAsset == "part.json")
        #expect(got.graphic == p.graphic)
    }

    @Test func corruptPartReportedOthersLoad() async throws {
        let root = tempRoot()
        let store = PersonalLibraryStore(rootURL: root)
        try store.write(makePart(id: "good"))
        try store.write(makePart(id: "bad"))
        try Data("{".utf8).write(to: store.directory(forLibraryID: "bad").appendingPathComponent("part.json"))
        let loaded = try store.load()
        #expect(loaded.parts.map(\.definition.libraryID) == ["good"])
        #expect(loaded.issues.count == 1)
        #expect(loaded.issues.first?.reason == .unreadableMetadata)

        let lib = PartsLibrary(bundledCatalogURL: catalogURL, personalStore: store)
        _ = await lib.allParts()
        #expect(await lib.lastLoadIssues.count == 1)
    }

    @Test func unsafeGraphicAssetNameReported() throws {
        let root = tempRoot()
        let store = PersonalLibraryStore(rootURL: root)
        try store.write(makePart(id: "good"))
        var evil = makePart(id: "evil")
        evil.definition.graphicAsset = "../../escaped.svg"
        try store.write(evil)
        let loaded = try store.load()
        #expect(loaded.parts.map(\.definition.libraryID) == ["good"])
        #expect(loaded.issues.map(\.reason) == [.invalidDefinition])
    }

    @Test func outOfRangeGeometryReported() throws {
        let store = PersonalLibraryStore(rootURL: tempRoot())
        try store.write(makePart(id: "good"))
        var huge = makePart(id: "huge")
        huge.definition.size = Vec2(x: 1e6, y: 5) // the definition would make documents unopenable
        try store.write(huge)
        let loaded = try store.load()
        #expect(loaded.parts.map(\.definition.libraryID) == ["good"])
        #expect(loaded.issues.map(\.reason) == [.invalidDefinition])
    }

    @Test func iCloudPlaceholderReportedNotDownloaded() throws {
        let root = tempRoot()
        let store = PersonalLibraryStore(rootURL: root)
        try store.write(makePart(id: "cloud"))
        let dir = try store.directory(forLibraryID: "cloud")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("part.json"))
        try Data().write(to: dir.appendingPathComponent(".part.json.icloud"))
        let loaded = try store.load()
        #expect(loaded.parts.isEmpty)
        #expect(loaded.issues.first?.reason == .notDownloaded)
    }

    @Test func unreadableRootThrows() throws {
        let root = tempRoot()
        try Data("x".utf8).write(to: root) // file where a directory is expected
        #expect(throws: (any Error).self) { try PersonalLibraryStore(rootURL: root).load() }
    }
}
