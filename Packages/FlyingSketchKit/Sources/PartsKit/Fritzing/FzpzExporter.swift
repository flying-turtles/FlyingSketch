import Foundation
import SketchCore

/// Writes a library part as a Fritzing-shaped `.fzpz` plus a FlyingSketch sidecar for lossless re-import.
public enum FzpzExporter {
    static let sidecarJSON = "flyingsketch.json"

    static func sidecarGraphicName(_ kind: GraphicKind) -> String { "flyingsketch." + kind.rawValue }

    public static func export(_ part: LibraryPart) throws -> Data {
        let def = part.definition
        let safe = PersonalLibraryStore.sanitize(def.libraryID)

        var zip = ZipWriter()
        zip.add("part.\(safe).fzp", data: Data(fzp(def, safeName: safe).utf8))
        zip.add("svg.breadboard.\(safe).svg", data: Data(svg(def, graphic: part.graphic).utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        zip.add(sidecarJSON, data: try encoder.encode(def))
        zip.add(sidecarGraphicName(def.graphicKind), data: part.graphic)
        return zip.finish()
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// SVG rect ids: `connector<N>` ids map to `connector<N>pin`; otherwise (or on any collision) the index is used.
    static func svgIds(_ connectors: [ConnectorDef]) -> [String] {
        let derived = connectors.map { c -> String? in
            guard c.id.hasPrefix("connector"), let n = Int(c.id.dropFirst("connector".count)), n >= 0,
                  c.id == "connector\(n)" else { return nil }
            return "connector\(n)pin"
        }
        let byIndex = connectors.indices.map { "connector\($0)pin" }
        let mixed = zip(derived, byIndex).map { $0 ?? $1 }
        return Set(mixed).count == mixed.count ? mixed : byIndex
    }

    private static func fzp(_ def: PartDefinition, safeName: String) -> String {
        var x = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        x += "<module moduleId=\"\(escape(def.libraryID))\" xmlns:flyingsketch=\"\(FzpDocument.namespace)\">\n"
        x += "<title>\(escape(def.title))</title>\n"
        x += "<label>\(escape(def.labelPrefix))</label>\n"
        x += "<tags>\n" + def.tags.map { "<tag>\(escape($0))</tag>\n" }.joined() + "</tags>\n"
        x += "<properties>\n"
        for k in def.properties.keys.sorted() {
            x += "<property name=\"\(escape(k))\">\(escape(def.properties[k] ?? ""))</property>\n"
        }
        if def.properties["family"] == nil, !def.family.isEmpty {
            x += "<property name=\"family\">\(escape(def.family))</property>\n"
        }
        x += "</properties>\n"
        x += "<views>\n<breadboardView>\n<layers image=\"breadboard/\(escape(safeName)).svg\">\n"
        x += "<layer layerId=\"breadboard\"/>\n</layers>\n</breadboardView>\n</views>\n"
        x += "<connectors>\n"
        let ids = svgIds(def.connectors)
        for (i, c) in def.connectors.enumerated() {
            x += "<connector id=\"\(escape(c.id))\" name=\"\(escape(c.name))\" type=\"\(c.kind.rawValue)\""
            if let r = c.role { x += " flyingsketch:role=\"\(r.rawValue)\"" }
            x += ">\n<description>\(escape(c.description))</description>\n"
            x += "<views><breadboardView><p layer=\"breadboard\" svgId=\"\(ids[i])\"/></breadboardView></views>\n"
            x += "</connector>\n"
        }
        x += "</connectors>\n"
        x += "<buses>\n"
        for (n, bus) in def.buses.enumerated() {
            x += "<bus id=\"bus\(n)\">\n"
            for id in bus { x += "<nodeMember connectorId=\"\(escape(id))\"/>\n" }
            x += "</bus>\n"
        }
        x += "</buses>\n</module>\n"
        return x
    }

    private static func svg(_ def: PartDefinition, graphic: Data) -> String {
        let w = def.size.x, h = def.size.y
        let mime = def.graphicKind == .png ? "image/png" : "image/svg+xml"
        var x = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        x += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(w)mm\" height=\"\(h)mm\" viewBox=\"0 0 \(w) \(h)\">\n"
        x += "<image x=\"0\" y=\"0\" width=\"\(w)\" height=\"\(h)\" href=\"data:\(mime);base64,\(graphic.base64EncodedString())\"/>\n"
        let ids = svgIds(def.connectors)
        for (i, c) in def.connectors.enumerated() {
            x += "<rect id=\"\(ids[i])\" x=\"\(c.position.x - 0.25)\" y=\"\(c.position.y - 0.25)\" width=\"0.5\" height=\"0.5\" fill=\"none\" stroke=\"none\"/>\n"
        }
        x += "</svg>\n"
        return x
    }
}
