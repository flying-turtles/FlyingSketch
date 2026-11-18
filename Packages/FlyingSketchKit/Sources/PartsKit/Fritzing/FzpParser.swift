import Foundation
import SketchCore

public enum PartImportError: Error, Equatable {
    case noFzp
    case multipleFzp
    case missingBreadboardSVG(String)
    case missingConnectorGeometry(String)
    case invalidFzp(String)
    case invalidSVG(String)
    case invalidArchive(String)
}

/// Raw content of an `.fzp` file (only what FlyingSketch uses).
struct FzpDocument {
    struct Connector {
        var id: String
        var name: String
        var type: String
        var description = ""
        var svgId: String?
        var legId: String?
        /// Raw `flyingsketch:role` attribute (explicit pin role), if any.
        var role: String?
    }

    /// Namespace of FlyingSketch's own fzp extension attributes (e.g. `flyingsketch:role` on `<connector>`).
    static let namespace = "https://github.com/flying-turtles/FlyingSketch"

    static let maxSize = 1024 * 1024

    var moduleId = ""
    var title = ""
    var label = ""
    var tags: [String] = []
    var properties: [String: String] = [:]
    var connectors: [Connector] = []
    var buses: [[String]] = []
    var breadboardImage: String?

    static func read(_ data: Data) throws -> FzpDocument {
        try PartInputGuard.check(data, max: maxSize) { PartImportError.invalidFzp($0) }
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), parser.parserError == nil else {
            throw PartImportError.invalidFzp(parser.parserError?.localizedDescription ?? "not XML")
        }
        guard !collector.doc.moduleId.isEmpty else { throw PartImportError.invalidFzp("missing moduleId") }
        return collector.doc
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var doc = FzpDocument()
        private var path: [String] = []
        private var text = ""
        private var propName: String?
        private var inBus = false
        /// Prefixes bound to `FzpDocument.namespace` (namespace processing is off, so attributes keep their qualified names).
        private var prefixes: Set<String> = []

        private var key: String { path.joined(separator: "/") }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String] = [:]) {
            path.append(name)
            text = ""
            for (k, v) in a where k.hasPrefix("xmlns:") && v == FzpDocument.namespace { prefixes.insert(String(k.dropFirst(6))) }
            switch key {
            case "module":
                doc.moduleId = a["moduleId"] ?? ""
            case "module/properties/property":
                propName = a["name"]
            case "module/connectors/connector":
                var c = Connector(id: a["id"] ?? "", name: a["name"] ?? "", type: a["type"] ?? "")
                c.role = prefixes.sorted().lazy.compactMap { a["\($0):role"] }.first
                doc.connectors.append(c)
            case "module/connectors/connector/views/breadboardView/p":
                if !doc.connectors.isEmpty, doc.connectors[doc.connectors.count - 1].svgId == nil {
                    doc.connectors[doc.connectors.count - 1].svgId = a["svgId"]
                    doc.connectors[doc.connectors.count - 1].legId = a["legId"]
                }
            case "module/views/breadboardView/layers":
                if doc.breadboardImage == nil { doc.breadboardImage = a["image"] }
            case "module/buses/bus":
                doc.buses.append([])
            case "module/buses/bus/nodeMember":
                if let id = a["connectorId"], !doc.buses.isEmpty { doc.buses[doc.buses.count - 1].append(id) }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "module/title": doc.title = t
            case "module/label": doc.label = t
            case "module/tags/tag": if !t.isEmpty { doc.tags.append(t) }
            case "module/properties/property":
                if let n = propName, doc.properties[n] == nil { doc.properties[n] = t }
                propName = nil
            case "module/connectors/connector/description":
                if !doc.connectors.isEmpty { doc.connectors[doc.connectors.count - 1].description = t }
            default: break
            }
            text = ""
            path.removeLast()
        }
    }
}

/// Pre-parse checks shared by fzp and SVG input.
public enum PartInputGuard {
    /// True when `data` passes the SVG import checks (size <= `FzpParser.maxSVGSize`, no NUL, no entity
    /// declarations). Renderers apply it to embedded SVGs, which arrive from documents and the pasteboard.
    public static func isAcceptableSVG(_ data: Data) -> Bool {
        (try? check(data, max: FzpParser.maxSVGSize) { PartImportError.invalidSVG($0) }) != nil
    }

    static func check(_ data: Data, max: Int, error: (String) -> PartImportError) throws {
        if data.count > max { throw error("too large") }
        if data.contains(0) { throw error("unsupported encoding") }
        if data.range(of: Data("<!ENTITY".utf8)) != nil { throw error("entity declarations not allowed") }
    }
}

public struct FzpParser {
    public static let maxSVGSize = 5 * 1024 * 1024
    static let defaultLegColor = RGBAColor(r: 0.55, g: 0.55, b: 0.55)
    static let defaultLegWidth = 0.6

    /// `svgFileName` is the breadboard graphic's original file name; the definition itself is keyed
    /// by content hash, so it is not stored.
    public static func parse(fzp: Data, breadboardSVG: Data, svgFileName: String) throws -> PartDefinition {
        let doc = try FzpDocument.read(fzp)
        try PartInputGuard.check(breadboardSVG, max: maxSVGSize) { PartImportError.invalidSVG($0) }
        let geometry: SVGGeometry
        do {
            geometry = try SVGGeometry(data: breadboardSVG)
        } catch {
            throw PartImportError.invalidSVG(String(describing: error))
        }

        var connectors: [ConnectorDef] = []
        for c in doc.connectors {
            guard let svgId = c.svgId, let position = geometry.centerMM(ofElement: svgId) else {
                throw PartImportError.missingConnectorGeometry(c.id)
            }
            var leg: LegSpec?
            if let legId = c.legId {
                guard let (start, end) = geometry.lineMM(ofElement: legId) else {
                    throw PartImportError.missingConnectorGeometry(c.id)
                }
                leg = LegSpec(origin: start, defaultEnd: end, color: legColor(geometry, legId),
                              width: legWidth(geometry, legId))
            }
            var pinRole: PinRole?
            if let raw = c.role {
                guard let explicit = PinRole(rawValue: raw) else {
                    throw PartImportError.invalidFzp("unknown role \(raw) on \(c.id)")
                }
                pinRole = explicit
            } else if kind(c.type) != .female {
                pinRole = role(forName: c.name)
            }
            connectors.append(ConnectorDef(
                id: c.id, name: c.name, description: c.description, kind: kind(c.type), position: position,
                role: pinRole, leg: leg))
        }

        let family = doc.properties["family"]
            ?? doc.properties.filter { $0.key.lowercased() == "family" }.sorted { $0.key < $1.key }.first?.value ?? ""
        var def = PartDefinition(
            libraryID: doc.moduleId, versionHash: "", title: doc.title, family: family,
            labelPrefix: doc.label.isEmpty ? "U" : doc.label, tags: doc.tags, properties: doc.properties,
            size: geometry.sizeMM, graphicAsset: "", graphicKind: .svg, connectors: connectors, buses: doc.buses)
        // Bounded geometry: an accepted definition must never make a saved document unopenable.
        do { try def.validateGeometry() } catch { throw PartImportError.invalidSVG("geometry out of range") }
        let hash: String
        do {
            hash = try PartHash.versionHash(definitionWithoutHash: def, graphic: breadboardSVG)
        } catch {
            throw PartImportError.invalidFzp("definition not encodable: \(error)")
        }
        def.versionHash = hash
        def.graphicAsset = "part-\(hash).svg"
        return def
    }

    static func kind(_ type: String) -> ConnectorKind {
        ConnectorKind(rawValue: type.lowercased()) ?? .male
    }

    // MARK: Leg style

    private static func style(_ g: SVGGeometry, _ id: String, _ name: String) -> String? {
        if let v = g.attribute(name, ofElement: id) { return v }
        guard let style = g.attribute("style", ofElement: id) else { return nil }
        for decl in style.split(separator: ";") {
            let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == name { return kv[1] }
        }
        return nil
    }

    private static func legColor(_ g: SVGGeometry, _ id: String) -> RGBAColor {
        guard let s = style(g, id, "stroke"), let c = parseHexColor(s) else { return defaultLegColor }
        return c
    }

    static func parseHexColor(_ s: String) -> RGBAColor? {
        var h = s.trimmingCharacters(in: .whitespaces)
        guard h.hasPrefix("#") else { return nil }
        h.removeFirst()
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return RGBAColor(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255,
                         b: Double(v & 0xFF) / 255)
    }

    private static func legWidth(_ g: SVGGeometry, _ id: String) -> Double {
        guard let s = style(g, id, "stroke-width") else { return defaultLegWidth }
        let digits = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "px", with: "")
        guard let w = Double(digits), w > 0 else { return defaultLegWidth }
        let mm = w * g.userUnitToMM
        return mm > 0 && mm.isFinite ? mm : defaultLegWidth
    }

    // MARK: Role heuristic

    private static let rolePatterns: [(PinRole, String)] = [
        (.ground, #"^(A|D|P)?GND\d*$|^VSS\d*$"#),
        (.power, #"^(3V3|3\.3V|5V|VIN|VCC|VDD)\d*$"#),
        (.i2cSDA, #"^SDA\d*$"#),
        (.i2cSCL, #"^SCL\d*$"#),
        (.spi, #"^(MOSI|MISO|SCLK|SCK|CS)\d*$"#),
        (.uart, #"^(U\d*)?(TX|RX)D?\d*$"#),
        (.digital, #"^(GPIO|IO|D)\d+$"#),
        (.analog, #"^(A\d+|ADC\d*)$"#),
    ]

    public static func role(forName name: String) -> PinRole? {
        let tokens = name.uppercased().split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".")) })
            .map(String.init)
        for (role, pattern) in rolePatterns {
            for t in tokens where t.range(of: pattern, options: .regularExpression) != nil { return role }
        }
        return nil
    }
}
