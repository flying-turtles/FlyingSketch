import Foundation
import SketchCore

public struct FzpzImporter {
    public static func importPart(_ data: Data) throws -> (definition: PartDefinition, graphic: Data) {
        let zip: ZipReader
        do { zip = try ZipReader(data: data) } catch { throw PartImportError.invalidArchive(String(describing: error)) }

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

    /// Fritzing names the entry `svg.breadboard.<basename>`; accept the bare basename too, case-insensitively.
    private static func svgEntry(named base: String, in names: [String]) -> String? {
        let wanted = ["svg.breadboard." + base, base]
        for w in wanted {
            if names.contains(w) { return w }
        }
        for w in wanted.map({ $0.lowercased() }) {
            if let n = names.first(where: { ($0 as NSString).lastPathComponent.lowercased() == w }) { return n }
        }
        return nil
    }
}
