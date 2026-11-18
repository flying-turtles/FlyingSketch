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
    var source: String
    var headers: [String: [String]]
}

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
            #expect(pins.map(\.name) == fixture.headers[header])
            for (i, pin) in pins.enumerated() {
                #expect(pin.description.hasPrefix("\(header) pin \(i + 1):"))
                if i > 0 { #expect(abs(pin.position.y - pins[i - 1].position.y - 2.54) < 0.01) }
            }
        }
        #expect(abs(j1[0].position.y - j3[0].position.y) < 0.01)
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
