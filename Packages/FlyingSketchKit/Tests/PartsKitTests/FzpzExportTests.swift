import Foundation
import Testing
import SketchCore
@testable import PartsKit

private func makePart(kind: GraphicKind = .png, title: String = "Photo Board", id: String = "my.part/1") throws -> LibraryPart {
    let graphic = kind == .png ? Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4, 5])
        : Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="20mm" height="10mm"><rect width="20" height="10"/></svg>"#.utf8)
    var def = PartDefinition(
        libraryID: id, versionHash: "", title: title, family: "boards", labelPrefix: "U", tags: ["a", "b&c"],
        properties: ["family": "boards", "note": "x<y"], size: Vec2(x: 20, y: 10), graphicAsset: "",
        graphicKind: kind,
        connectors: [
            ConnectorDef(id: "p1", name: "VCC", description: "power & co", kind: .male, position: Vec2(x: 1.5, y: 2), role: .power),
            ConnectorDef(id: "p2", name: "GND", kind: .pad, position: Vec2(x: 3.25, y: 8), role: .ground),
            ConnectorDef(id: "p3", name: "Q", kind: .female, position: Vec2(x: 10, y: 5)),
        ],
        buses: [["p1", "p3"]])
    let hash = try PartHash.versionHash(definitionWithoutHash: def, graphic: graphic)
    def.versionHash = hash
    def.graphicAsset = "part-\(hash).\(kind.rawValue)"
    return LibraryPart(definition: def, graphic: graphic, source: .personal)
}

private func rebuild(_ zipData: Data, drop: Set<String> = [], replace: [String: Data] = [:]) throws -> Data {
    let r = try ZipReader(data: zipData)
    var w = ZipWriter()
    for n in r.entryNames where !drop.contains(n) {
        let d = try replace[n] ?? r.data(for: n)
        w.add(n, data: d)
    }
    return w.finish()
}

@Suite struct FzpzExportTests {
    @Test func zipWriterRoundTripsThroughReader() throws {
        var w = ZipWriter()
        w.add("a.txt", data: Data("hello".utf8))
        w.add("dir/ü.bin", data: Data())
        w.add("big", data: Data(repeating: 7, count: 100_000))
        let r = try ZipReader(data: w.finish())
        #expect(r.entryNames == ["a.txt", "dir/ü.bin", "big"])
        #expect(try r.data(for: "a.txt") == Data("hello".utf8))
        #expect(try r.data(for: "dir/ü.bin").isEmpty)
        #expect(try r.data(for: "big").count == 100_000)
    }

    @Test func exportImportIsLossless() throws {
        let part = try makePart()
        let out = try FzpzImporter.importPart(FzpzExporter.export(part))
        #expect(out.definition == part.definition)
        #expect(out.graphic == part.graphic)
    }

    @Test func svgPartIsLossless() throws {
        let part = try makePart(kind: .svg)
        let out = try FzpzImporter.importPart(FzpzExporter.export(part))
        #expect(out.definition == part.definition)
        #expect(out.graphic == part.graphic)
    }

    @Test func exportIsFritzingShaped() throws {
        let part = try makePart()
        let archive = try FzpzExporter.export(part)
        let stripped = try rebuild(archive, drop: ["flyingsketch.json", "flyingsketch.png"])
        let out = try FzpzImporter.importPart(stripped).definition
        #expect(out.libraryID == part.definition.libraryID)
        #expect(abs(out.size.x - 20) < 0.01 && abs(out.size.y - 10) < 0.01)
        #expect(out.connectors.map(\.id) == ["p1", "p2", "p3"])
        #expect(out.connectors.map(\.name) == ["VCC", "GND", "Q"])
        for (a, b) in Swift.zip(out.connectors, part.definition.connectors) {
            #expect(abs(a.position.x - b.position.x) < 0.01 && abs(a.position.y - b.position.y) < 0.01)
            #expect(a.role == b.role || b.role == nil)
        }
        #expect(out.buses == [["p1", "p3"]])
        #expect(out.family == "boards")
    }

    @Test func svgIdsFollowConnectorIds() {
        func defs(_ ids: [String]) -> [ConnectorDef] { ids.map { ConnectorDef(id: $0, name: $0, kind: .male, position: .zero) } }
        #expect(FzpzExporter.svgIds(defs(["connector3", "connector0"])) == ["connector3pin", "connector0pin"])
        #expect(FzpzExporter.svgIds(defs(["p1", "connector7"])) == ["connector0pin", "connector7pin"])
        // Collision between a derived id and an index fallback: all by index.
        #expect(FzpzExporter.svgIds(defs(["p1", "connector0"])) == ["connector0pin", "connector1pin"])
        #expect(FzpzExporter.svgIds(defs(["connector01", "connector-1"])) == ["connector0pin", "connector1pin"])
    }

    @Test func tamperedSidecarIsRejected() throws {
        let part = try makePart()
        var def = part.definition
        def.connectors[0].position = Vec2(x: 1e9, y: 0)
        let json = try JSONEncoder().encode(def)
        let bad = try rebuild(FzpzExporter.export(part), replace: ["flyingsketch.json": json])
        do {
            _ = try FzpzImporter.importPart(bad)
            Issue.record("expected failure")
        } catch let e as PartImportError {
            guard case .invalidFzp(let m) = e else { Issue.record("wrong error \(e)"); return }
            #expect(m.hasPrefix("flyingsketch sidecar:"))
        }
    }

    @Test func missingSidecarGraphicIsRejected() throws {
        let bad = try rebuild(FzpzExporter.export(makePart()), drop: ["flyingsketch.png"])
        #expect(throws: PartImportError.invalidFzp("flyingsketch sidecar: missing graphic")) {
            try FzpzImporter.importPart(bad)
        }
    }

    @Test func xmlSpecialCharsEscaped() throws {
        let part = try makePart(title: "A&B <x>")
        let archive = try FzpzExporter.export(part)
        let stripped = try rebuild(archive, drop: ["flyingsketch.json", "flyingsketch.png"])
        #expect(try FzpzImporter.importPart(stripped).definition.title == "A&B <x>")
        #expect(try FzpzImporter.importPart(archive).definition.title == "A&B <x>")
    }
}
