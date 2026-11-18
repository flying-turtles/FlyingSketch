import Foundation
import PartsKit
import SketchCore

struct BuildError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

/// A converted part plus what the attribution needs.
struct LoadedPart {
    var entry: ManifestEntry
    var definition: PartDefinition
    var graphic: Data
    var authors: [String]
    /// Source commit (nil for custom parts).
    var commit: String?
}

/// Reads one manifest entry from its source and converts it.
struct PartLoader {
    var vendorDir: URL
    var customDir: URL

    func load(_ entry: ManifestEntry) throws -> LoadedPart {
        switch entry.source {
        case .adafruit:
            let root = vendorDir.appendingPathComponent("Fritzing-Library")
            let data = try read(root.appendingPathComponent(entry.fzp))
            let (def, svg) = try FzpzImporter.importPart(data)
            let zip = try ZipReader(data: data)
            guard let fzpName = zip.entryNames.first(where: { $0.lowercased().hasSuffix(".fzp") }) else {
                throw BuildError("no .fzp in \(entry.fzp)")
            }
            let meta = try FzpMeta.read(zip.data(for: fzpName))
            return LoadedPart(entry: entry, definition: def, graphic: svg, authors: meta.authors,
                              commit: try commit(of: root))
        case .fritzingParts:
            let root = vendorDir.appendingPathComponent("fritzing-parts")
            let fzpURL = root.appendingPathComponent(entry.fzp)
            // A part in core/contrib/obsolete/user keeps its graphics under svg/<same dir>/.
            guard let dir = entry.fzp.split(separator: "/").first.map(String.init) else {
                throw BuildError("bad fzp path \(entry.fzp)")
            }
            let svgRoot = root.appendingPathComponent("svg").appendingPathComponent(dir)
            return try convert(entry, fzpURL: fzpURL, svgRoot: svgRoot, commit: try commit(of: root))
        case .custom:
            let fzpURL = customDir.appendingPathComponent(entry.fzp)
            return try convert(entry, fzpURL: fzpURL, svgRoot: fzpURL.deletingLastPathComponent(), commit: nil)
        }
    }

    private func convert(_ entry: ManifestEntry, fzpURL: URL, svgRoot: URL, commit: String?) throws -> LoadedPart {
        let fzp = try read(fzpURL)
        let meta = try FzpMeta.read(fzp)
        guard let image = meta.breadboardImage else { throw BuildError("\(entry.fzp): no breadboard image") }
        let svg = try read(svgRoot.appendingPathComponent(image))
        let def = try FzpParser.parse(fzp: fzp, breadboardSVG: svg, svgFileName: (image as NSString).lastPathComponent)
        return LoadedPart(entry: entry, definition: def, graphic: svg, authors: meta.authors, commit: commit)
    }

    private func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch { throw BuildError("cannot read \(url.path)") }
    }

    /// Commit of a repo fetched by `Tools/fetch-parts.sh` (detached HEAD).
    private func commit(of repo: URL) throws -> String {
        let head = try String(decoding: read(repo.appendingPathComponent(".git/HEAD")), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.count == 40, head.allSatisfy(\.isHexDigit) else {
            throw BuildError("\(repo.lastPathComponent) is not at a pinned commit (run Tools/fetch-parts.sh)")
        }
        return head
    }
}

/// The two `.fzp` fields the builder needs that `PartDefinition` does not carry.
struct FzpMeta {
    var authors: [String] = []
    var breadboardImage: String?

    static func read(_ data: Data) throws -> FzpMeta {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw BuildError("fzp is not XML") }
        return collector.meta
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var meta = FzpMeta()
        private var path: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String] = [:]) {
            path.append(name)
            text = ""
            if path.joined(separator: "/") == "module/views/breadboardView/layers", meta.breadboardImage == nil {
                meta.breadboardImage = a["image"]
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if path.joined(separator: "/") == "module/author" {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !meta.authors.contains(t) { meta.authors.append(t) }
            }
            text = ""
            path.removeLast()
        }
    }
}
