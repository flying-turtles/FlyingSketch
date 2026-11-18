import Foundation
import SketchCore

public struct FzpzImporter {
    public static func importPart(_ data: Data) throws -> (definition: PartDefinition, graphic: Data) {
        let zip: ZipReader
        do { zip = try ZipReader(data: data) } catch { throw PartImportError.invalidArchive(String(describing: error)) }

        if zip.entryNames.contains(FzpzExporter.sidecarJSON) { return try importSidecar(zip) }

        let fzps = zip.entryNames.filter { $0.lowercased().hasSuffix(".fzp") }
        guard !fzps.isEmpty else { throw PartImportError.noFzp }
        guard fzps.count == 1 else { throw PartImportError.multipleFzp }

        let fzpData: Data
        do { fzpData = try zip.data(for: fzps[0]) } catch { throw PartImportError.invalidArchive(String(describing: error)) }
        let doc = try FzpDocument.read(fzpData)

        guard let image = doc.breadboardImage, !image.isEmpty else { throw PartImportError.missingBreadboardSVG("") }
        let base = (image as NSString).lastPathComponent
        guard let entry = svgEntry(named: base, in: zip.entryNames) else {
            throw PartImportError.missingBreadboardSVG(base)
        }
        let svg: Data
        do { svg = try zip.data(for: entry) } catch { throw PartImportError.invalidArchive(String(describing: error)) }

        let def = try FzpParser.parse(fzp: fzpData, breadboardSVG: svg, svgFileName: base)
        return (def, svg)
    }

    /// Lossless FlyingSketch sidecar path; never falls back to the fzp.
    private static func importSidecar(_ zip: ZipReader) throws -> (definition: PartDefinition, graphic: Data) {
        func fail(_ m: String) -> PartImportError { .invalidFzp("flyingsketch sidecar: " + m) }
        let json: Data
        do { json = try zip.data(for: FzpzExporter.sidecarJSON) } catch { throw PartImportError.invalidArchive(String(describing: error)) }
        try PartInputGuard.check(json, max: FzpDocument.maxSize) { fail($0) }
        var def: PartDefinition
        do { def = try JSONDecoder().decode(PartDefinition.self, from: json) } catch { throw fail("\(error)") }

        let name = FzpzExporter.sidecarGraphicName(def.graphicKind)
        guard zip.entryNames.contains(name) else { throw fail("missing graphic") }
        let graphic: Data
        do { graphic = try zip.data(for: name) } catch { throw PartImportError.invalidArchive(String(describing: error)) }
        if def.graphicKind == .svg {
            try PartInputGuard.check(graphic, max: FzpParser.maxSVGSize) { fail($0) }
        }

        def.versionHash = ""
        def.graphicAsset = ""
        do {
            def.versionHash = try PartHash.versionHash(definitionWithoutHash: def, graphic: graphic)
            def.graphicAsset = "part-\(def.versionHash).\(def.graphicKind.rawValue)"
            try def.validate()
        } catch { throw fail("\(error)") }
        return (def, graphic)
    }

    /// Fritzing names the entry `svg.breadboard.<basename>`; match case-insensitively.
    private static func svgEntry(named base: String, in names: [String]) -> String? {
        let wanted = ("svg.breadboard." + base).lowercased()
        return names.first { ($0 as NSString).lastPathComponent.lowercased() == wanted }
    }
}
