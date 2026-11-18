import Foundation
import PartsKit
import SketchCore

/// `catalog.json` row.
struct CatalogEntry: Codable {
    var id: String
    var title: String
    var family: String
    var tags: [String]
    var file: String
}

/// Writes `catalog.json`, `parts/`, `graphics/` and `ATTRIBUTION.md`. Output is built in a temporary sibling
/// directory and swapped in only when complete, so a failed run leaves the previous catalog intact.
struct CatalogWriter {
    var outDir: URL

    func write(_ parts: [LoadedPart]) throws {
        let fm = FileManager.default
        let staging = outDir.deletingLastPathComponent()
            .appendingPathComponent(".\(outDir.lastPathComponent).staging-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try writeAll(parts, to: staging)
        if fm.fileExists(atPath: outDir.path) {
            _ = try fm.replaceItemAt(outDir, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: outDir)
        }
    }

    private func writeAll(_ parts: [LoadedPart], to dir: URL) throws {
        let parts = try parts.sorted { $0.entry.id < $1.entry.id }.map(rounded)
        let fm = FileManager.default
        let graphicsDir = dir.appendingPathComponent("graphics")
        for sub in ["parts", "graphics"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var catalog: [CatalogEntry] = []
        for p in parts {
            let file = "parts/\(p.entry.id).json"
            try (encoder.encode(p.definition) + Data("\n".utf8)).write(to: dir.appendingPathComponent(file))
            try p.graphic.write(to: graphicsDir.appendingPathComponent(p.definition.graphicAsset))
            catalog.append(CatalogEntry(id: p.entry.id, title: p.definition.title, family: p.definition.family,
                                        tags: p.definition.tags, file: file))
        }
        try (encoder.encode(catalog) + Data("\n".utf8)).write(to: dir.appendingPathComponent("catalog.json"))
        try Data(attribution(parts).utf8).write(to: dir.appendingPathComponent("ATTRIBUTION.md"))
    }

    /// Geometry rounded to 1e-6 mm (clean, stable JSON); hash and graphic name recomputed for the rounded definition.
    private func rounded(_ part: LoadedPart) throws -> LoadedPart {
        func r(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }
        func r(_ v: Vec2) -> Vec2 { Vec2(x: r(v.x), y: r(v.y)) }
        var p = part
        var def = p.definition
        def.size = r(def.size)
        for i in def.connectors.indices {
            def.connectors[i].position = r(def.connectors[i].position)
            if var leg = def.connectors[i].leg {
                leg.origin = r(leg.origin)
                leg.defaultEnd = r(leg.defaultEnd)
                leg.width = r(leg.width)
                def.connectors[i].leg = leg
            }
        }
        def.versionHash = try PartHash.versionHash(definitionWithoutHash: def, graphic: p.graphic)
        def.graphicAsset = "part-\(def.versionHash).svg"
        p.definition = def
        return p
    }

    private func attribution(_ parts: [LoadedPart]) -> String {
        var s = """
        # Part attribution

        Parts from Fritzing libraries are licensed under CC-BY-SA 3.0
        (https://creativecommons.org/licenses/by-sa/3.0/). Their definitions were converted to
        FlyingSketch's format and their breadboard graphics are included unmodified.

        Custom parts were authored for FlyingSketch and are licensed under MIT (Copyright Lars Grof).


        """
        for p in parts {
            s += "## \(p.entry.id)\n\n"
            s += "- Title: \(p.definition.title)\n"
            if let repo = p.entry.source.repositoryURL, let commit = p.commit {
                s += "- Source: \(repo)\n"
                s += "- Path: \(p.entry.fzp)\n"
                s += "- Commit: \(commit)\n"
                s += "- Authors: \(p.authors.isEmpty ? "not stated in the .fzp (see the source repository history)" : p.authors.joined(separator: ", "))\n"
                s += "- License: CC-BY-SA 3.0\n\n"
            } else {
                s += "- Source: FlyingSketch custom part (Tools/custom-parts/\(p.entry.fzp))\n"
                s += "- Authors: \(p.authors.isEmpty ? "Lars Grof" : p.authors.joined(separator: ", "))\n"
                s += "- License: MIT\n\n"
            }
        }
        return s
    }
}
