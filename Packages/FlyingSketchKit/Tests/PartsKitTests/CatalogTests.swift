import Foundation
import Testing
import SketchCore
@testable import PartsKit

/// Repository root (this file is Packages/FlyingSketchKit/Tests/PartsKitTests/CatalogTests.swift).
private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let catalogDir = repoRoot.appendingPathComponent("App/Catalog")

private struct CatalogRow: Decodable {
    var id: String
    var title: String
    var family: String
    var tags: [String]
    var file: String
}

private struct ManifestRow: Decodable {
    var source: String
    var fzp: String
    var id: String
}

private struct PinFixture: Decodable {
    struct Pin: Decodable {
        var name: String
        /// Espressif "Type" column: P power, G ground, I input, I/O/T GPIO.
        var type: String
        var function: String
    }

    var source: String
    var headers: [String: [Pin]]
}

/// Espressif pin type -> role the board part must declare.
private let roleForEspressifType: [String: PinRole] = ["P": .power, "G": .ground, "I/O/T": .digital, "I": .other]

private func catalog() throws -> [CatalogRow] {
    try JSONDecoder().decode([CatalogRow].self, from: Data(contentsOf: catalogDir.appendingPathComponent("catalog.json")))
}

private func manifest() throws -> [ManifestRow] {
    try JSONDecoder().decode([ManifestRow].self,
                             from: Data(contentsOf: repoRoot.appendingPathComponent("Tools/catalog-manifest.json")))
}

private func part(_ id: String) throws -> PartDefinition {
    try JSONDecoder().decode(PartDefinition.self,
                             from: Data(contentsOf: catalogDir.appendingPathComponent("parts/\(id).json")))
}

@Suite struct CatalogTests {
    static let minimumSet = [
        "esp32-s3-devkitc-1", "esp32-c3-devkitm-1", "breadboard-full", "breadboard-half", "resistor", "led-5mm",
        "pushbutton", "potentiometer", "dht22", "bme280-breakout", "hc-sr04", "pir-hc-sr501", "photoresistor",
    ]

    @Test func catalogContainsMinimumSet() throws {
        let rows = try catalog()
        let manifestIDs = try manifest().map(\.id)
        #expect(Set(Self.minimumSet).isSubset(of: manifestIDs))
        #expect(rows.map(\.id) == manifestIDs.sorted())
        for row in rows {
            #expect(row.file == "parts/\(row.id).json")
            let def = try part(row.id)
            #expect(def.title == row.title)
            #expect(!def.connectors.isEmpty, "\(row.id) has no connectors")
            #expect(Set(def.connectors.map(\.id)).count == def.connectors.count, "\(row.id) duplicate connector ids")
            // Graphic is the unmodified source file the definition was hashed with.
            let graphic = try Data(contentsOf: catalogDir.appendingPathComponent("graphics/\(def.graphicAsset)"))
            #expect(try PartHash.versionHash(definitionWithoutHash: def, graphic: graphic) == def.versionHash, "\(row.id)")
            #expect(def.graphicAsset == "part-\(def.versionHash).svg")
            #expect(throws: Never.self, "\(row.id) fails validation") { try def.validate() } // placeable
        }
    }

    @Test(arguments: [
        ("esp32-s3-devkitc-1", "esp32s3-devkitc1-pins", 22),
        ("esp32-c3-devkitm-1", "esp32c3-devkitm1-pins", 15),
    ])
    func esp32BoardsMatchEspressifPinout(id: String, fixtureName: String, pinsPerHeader: Int) throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(fixtureName)", withExtension: "json"))
        let fixture = try JSONDecoder().decode(PinFixture.self, from: Data(contentsOf: url))
        #expect(fixture.source.hasPrefix("https://docs.espressif.com/"))
        let def = try part(id)
        #expect(def.connectors.count == 2 * pinsPerHeader)
        #expect(def.connectors.allSatisfy { $0.kind == .male })

        // Headers from geometry: J1 is the left column, J3 the right one; pin 1 is at the top (antenna end).
        let minX = try #require(def.connectors.map(\.position.x).min())
        let maxX = try #require(def.connectors.map(\.position.x).max())
        let j1 = def.connectors.filter { abs($0.position.x - minX) < 0.01 }.sorted { $0.position.y < $1.position.y }
        let j3 = def.connectors.filter { abs($0.position.x - maxX) < 0.01 }.sorted { $0.position.y < $1.position.y }
        #expect(abs((maxX - minX) - 22.86) < 0.01)
        for (header, pins) in [("J1", j1), ("J3", j3)] {
            #expect(pins.count == pinsPerHeader)
            let expected = try #require(fixture.headers[header])
            #expect(pins.map(\.name) == expected.map(\.name))
            #expect(pins.map(\.role) == expected.map { roleForEspressifType[$0.type] })
            #expect(pins.allSatisfy { $0.role != nil })
            for (i, pin) in pins.enumerated() {
                #expect(pin.description.hasPrefix("\(header) pin \(i + 1):"))
                if i > 0 { #expect(abs(pin.position.y - pins[i - 1].position.y - 2.54) < 0.01) }
            }
        }
        #expect(abs(j1[0].position.y - j3[0].position.y) < 0.01)
    }

    /// Same-named power / ground header pins are tied on the PCB: each such name group is exactly one bus.
    @Test(arguments: ["esp32-s3-devkitc-1", "esp32-c3-devkitm-1"])
    func esp32PowerAndGroundPinsAreBused(id: String) throws {
        let def = try part(id)
        let groups = Dictionary(grouping: def.connectors.filter { $0.role == .power || $0.role == .ground }, by: \.name)
        #expect(groups.keys.contains("3V3"))
        for (name, pins) in groups where pins.count > 1 {
            let ids = Set(pins.map(\.id))
            let containing = def.buses.filter { !Set($0).isDisjoint(with: ids) }
            #expect(containing.count == 1, "\(id) \(name): \(containing.count) buses")
            #expect(Set(containing.first ?? []) == ids, "\(id) \(name)")
        }
        #expect(def.buses.allSatisfy { $0.count > 1 })
    }

    @Test func pushbuttonPlugsAllFourLegsIntoFullBreadboard() throws {
        let board = try part("breadboard-full")
        let button = try part("pushbutton")
        #expect(button.connectors.count == 4)
        #expect(Set(button.connectors.map(\.name)) == ["Pin 1", "Pin 2", "Pin 3", "Pin 4"])
        #expect(Set(button.buses.map(Set.init)) == [["connector0", "connector1"], ["connector2", "connector3"]])

        var doc = SketchDocument()
        doc.parts = [board.key: board, button.key: button]
        let bb = PartInstance(definitionKey: board.key, center: Vec2(x: 0, y: 0), label: "BB1")
        doc.objects.append(.part(bb))
        // Drop the button so its top-left leg (Pin 3) sits exactly on a terminal-strip hole (row F of column 10, so the legs straddle the centre gap).
        let hole = try #require(connectorPositions(bb, board)["pin10F"])
        var sw = PartInstance(definitionKey: button.key, center: .zero, label: "S1")
        let leg = try #require(connectorPositions(sw, button)["connector2"])
        sw.center = hole - leg
        doc.objects.append(.part(sw))
        let plugged = contacts(in: doc).filter { $0.male.part == sw.id }
        #expect(plugged.count == 4)
    }

    /// Board and breadboard share the 2.54 mm grid (guards SVG unit handling, e.g. Illustrator px at 72 dpi).
    @Test(arguments: [("esp32-s3-devkitc-1", 44), ("esp32-c3-devkitm-1", 30)])
    func boardPlugsAllPinsIntoFullBreadboard(id: String, pins: Int) throws {
        let board = try part("breadboard-full")
        let mcu = try part(id)
        var doc = SketchDocument()
        doc.parts = [board.key: board, mcu.key: mcu]
        let bb = PartInstance(definitionKey: board.key, center: Vec2(x: 0, y: 0), label: "BB1")
        doc.objects.append(.part(bb))
        let holes = connectorPositions(bb, board)
        // Rotated a quarter turn the headers run along the strips; J1 pin 1 goes into row C or J of column 30
        // (pins then run towards column 1).
        var best = 0
        for row in ["C", "J"] {
            var u = PartInstance(definitionKey: mcu.key, center: .zero, quarterTurns: 1, label: "U1")
            let pin1 = try #require(connectorPositions(u, mcu)["connector0"])
            u.center = try #require(holes["pin30\(row)"]) - pin1
            var d = doc
            d.objects.append(.part(u))
            best = max(best, contacts(in: d).filter { $0.male.part == u.id }.count)
        }
        #expect(best == pins)
    }

    @Test func attributionListsEveryPart() throws {
        let text = try String(contentsOf: catalogDir.appendingPathComponent("ATTRIBUTION.md"), encoding: .utf8)
        let script = try String(contentsOf: repoRoot.appendingPathComponent("Tools/fetch-parts.sh"), encoding: .utf8)
        func pinnedSHA(_ variable: String) throws -> String {
            let line = try #require(script.split(separator: "\n").first { $0.hasPrefix(variable + "=") })
            return line.split(separator: "\"")[1].description
        }
        let commits = ["fritzing-parts": try pinnedSHA("FRITZING_PARTS_SHA"), "adafruit": try pinnedSHA("ADAFRUIT_LIBRARY_SHA")]
        let sections = text.components(separatedBy: "\n## ").dropFirst()
        let byID = Dictionary(uniqueKeysWithValues: sections.map { s in (String(s.prefix { $0 != "\n" }), s) })
        for row in try manifest() {
            let section = try #require(byID[row.id], "\(row.id) missing from ATTRIBUTION.md")
            let authors = section.split(separator: "\n").first { $0.hasPrefix("- Authors: ") }
            #expect((authors?.count ?? 0) > "- Authors: ".count, "\(row.id) lists no authors")
            if row.source == "custom" {
                #expect(section.contains("- License: MIT"))
            } else {
                #expect(section.contains("- Path: \(row.fzp)\n"))
                #expect(section.contains("- Commit: \(try #require(commits[row.source]))\n"))
                #expect(section.contains("- License: CC-BY-SA 3.0"))
            }
        }
        #expect(byID.count == (try catalog()).count)
    }
}
