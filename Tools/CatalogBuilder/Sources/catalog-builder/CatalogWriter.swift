import Foundation
import SketchCore

/// `catalog.json` row.
struct CatalogEntry: Codable {
    var id: String
    var title: String
    var family: String
    var tags: [String]
    var file: String
}

/// Writes `catalog.json`, `parts/`, `graphics/` and `ATTRIBUTION.md`, replacing previous output.
struct CatalogWriter {
    var outDir: URL

    func write(_ parts: [LoadedPart]) throws {
        let parts = parts.sorted { $0.entry.id < $1.entry.id }
        let fm = FileManager.default
        let partsDir = outDir.appendingPathComponent("parts")
        let graphicsDir = outDir.appendingPathComponent("graphics")
        for dir in [partsDir, graphicsDir] {
            if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var catalog: [CatalogEntry] = []
        for p in parts {
            let file = "parts/\(p.entry.id).json"
            try (encoder.encode(p.definition) + Data("\n".utf8)).write(to: outDir.appendingPathComponent(file))
            try p.graphic.write(to: graphicsDir.appendingPathComponent(p.definition.graphicAsset))
            catalog.append(CatalogEntry(id: p.entry.id, title: p.definition.title, family: p.definition.family,
                                        tags: p.definition.tags, file: file))
        }
        try (encoder.encode(catalog) + Data("\n".utf8)).write(to: outDir.appendingPathComponent("catalog.json"))
        try Data(attribution(parts).utf8).write(to: outDir.appendingPathComponent("ATTRIBUTION.md"))
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
