import Foundation
import SketchCore

public enum SVGError: Error, Equatable, Sendable {
    case notSVG
    case missingSize
    case unsupported(String)
}

/// Locates elements by id inside an SVG and reports their geometry in millimetres
/// (origin at the top-left of the SVG's viewport, y down).
///
/// Units: `in` 25.4 mm, `cm` 10 mm, `mm`, `pt` 25.4/72, `px` and unitless 25.4/90 (Fritzing's
/// legacy 90 dpi). Percent or missing sizes throw `.missingSize`.
///
/// User units: with a `viewBox` they scale to fill the size (`preserveAspectRatio` defaults to
/// `xMidYMid meet`; `none` stretches). Without a `viewBox`, one user unit = size / numeric
/// width, i.e. the unit of the size attribute (almost always px in Fritzing files).
///
/// Elements with `display="none"` still report geometry. Unparseable `transform` attributes
/// are treated as identity. `<use>` is unsupported (its id yields nil).
public struct SVGGeometry: Sendable {
    public let sizeMM: Vec2

    private struct Element: Sendable {
        var name: String
        var attrs: [String: String]
        var ctm: SVGAffine   // element's user space -> root user space
    }

    private let userToMM: SVGAffine
    private let elements: [String: Element]

    public init(data: Data) throws {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        guard let root = collector.rootAttrs else { throw SVGError.notSVG }

        guard let w = Self.length(root["width"]), let h = Self.length(root["height"]),
              w.value > 0, h.value > 0
        else { throw SVGError.missingSize }
        let size = Vec2(x: w.mm, y: h.mm)
        sizeMM = size

        var map = SVGAffine.scale(size.x / w.value, size.y / h.value)
        if let vb = Self.viewBox(root["viewBox"]) {
            let none = root["preserveAspectRatio"]?.split(separator: " ").contains("none") ?? false
            var sx = size.x / vb.w, sy = size.y / vb.h
            var tx = 0.0, ty = 0.0
            if !none {
                let s = min(sx, sy)
                tx = (size.x - vb.w * s) / 2
                ty = (size.y - vb.h * s) / 2
                sx = s; sy = s
            }
            map = .translate(tx, ty) * .scale(sx, sy) * .translate(-vb.x, -vb.y)
        }
        userToMM = map
        elements = collector.elements
    }

    /// Center of the transformed bounding box of the element with `id`.
    public func centerMM(ofElement id: String) -> Vec2? {
        guard let pts = points(of: id), !pts.isEmpty else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return Vec2(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
    }

    /// Endpoints of a `<line>`, or of a `<path>` made of a single `M` + straight segment.
    public func lineMM(ofElement id: String) -> (Vec2, Vec2)? {
        guard let el = elements[id] else { return nil }
        let m = userToMM * el.ctm
        switch el.name {
        case "line":
            guard let x1 = num(el, "x1"), let y1 = num(el, "y1"),
                  let x2 = num(el, "x2"), let y2 = num(el, "y2") else { return nil }
            return (m.apply(Vec2(x: x1, y: y1)), m.apply(Vec2(x: x2, y: y2)))
        case "path":
            guard let d = el.attrs["d"], let line = SVGPathParser.parse(d)?.singleLine else { return nil }
            return (m.apply(line.0), m.apply(line.1))
        default:
            return nil
        }
    }

    // MARK: - Internals

    private func num(_ el: Element, _ key: String, default def: Double? = nil) -> Double? {
        guard let s = el.attrs[key] else { return def }
        var sc = SVGScanner(s)
        return sc.number()
    }

    /// Transformed (mm) points whose bounding box is the element's bounds.
    private func points(of id: String) -> [Vec2]? {
        guard let el = elements[id] else { return nil }
        let m = userToMM * el.ctm
        var local: [Vec2]
        switch el.name {
        case "rect":
            guard let w = num(el, "width"), let h = num(el, "height"), w >= 0, h >= 0 else { return nil }
            let x = num(el, "x", default: 0)!, y = num(el, "y", default: 0)!
            local = [Vec2(x: x, y: y), Vec2(x: x + w, y: y), Vec2(x: x + w, y: y + h), Vec2(x: x, y: y + h)]
        case "circle":
            guard let r = num(el, "r"), r >= 0 else { return nil }
            local = Self.box(cx: num(el, "cx", default: 0)!, cy: num(el, "cy", default: 0)!, rx: r, ry: r)
        case "ellipse":
            guard let rx = num(el, "rx"), let ry = num(el, "ry"), rx >= 0, ry >= 0 else { return nil }
            local = Self.box(cx: num(el, "cx", default: 0)!, cy: num(el, "cy", default: 0)!, rx: rx, ry: ry)
        case "line":
            guard let x1 = num(el, "x1"), let y1 = num(el, "y1"),
                  let x2 = num(el, "x2"), let y2 = num(el, "y2") else { return nil }
            local = [Vec2(x: x1, y: y1), Vec2(x: x2, y: y2)]
        case "polygon", "polyline":
            guard let s = el.attrs["points"] else { return nil }
            var sc = SVGScanner(s)
            local = []
            while let x = sc.number(), let y = sc.number() { local.append(Vec2(x: x, y: y)) }
            if local.isEmpty { return nil }
        case "path":
            guard let d = el.attrs["d"], let shape = SVGPathParser.parse(d) else { return nil }
            local = shape.points
        default:
            return nil
        }
        return local.map(m.apply)
    }

    private static func box(cx: Double, cy: Double, rx: Double, ry: Double) -> [Vec2] {
        [Vec2(x: cx - rx, y: cy - ry), Vec2(x: cx + rx, y: cy - ry),
         Vec2(x: cx + rx, y: cy + ry), Vec2(x: cx - rx, y: cy + ry)]
    }

    private static func length(_ s: String?) -> (value: Double, mm: Double)? {
        guard let s else { return nil }
        var sc = SVGScanner(s.trimmingCharacters(in: .whitespaces))
        guard let v = sc.readNumber() else { return nil }
        let unit = sc.rest.trimmingCharacters(in: .whitespaces).lowercased()
        let perUnit: Double
        switch unit {
        case "", "px": perUnit = 25.4 / 90
        case "in": perUnit = 25.4
        case "mm": perUnit = 1
        case "cm": perUnit = 10
        case "pt": perUnit = 25.4 / 72
        default: return nil   // %, em, ... unsupported
        }
        return (v, v * perUnit)
    }

    private static func viewBox(_ s: String?) -> (x: Double, y: Double, w: Double, h: Double)? {
        guard let s else { return nil }
        var sc = SVGScanner(s)
        guard let x = sc.number(), let y = sc.number(), let w = sc.number(), let h = sc.number(),
              w > 0, h > 0 else { return nil }
        return (x, y, w, h)
    }

    /// One-pass collector: root attributes plus id -> element with accumulated transform.
    private final class Collector: NSObject, XMLParserDelegate {
        var rootAttrs: [String: String]?
        var elements: [String: Element] = [:]
        private var stack: [SVGAffine] = []
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attrs: [String: String] = [:]) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if depth == 0 {
                guard name == "svg" else { parser.abortParsing(); return }
                rootAttrs = attrs
                stack.append(.identity)   // root transform ignored
            } else {
                let own = attrs["transform"].flatMap(SVGAffine.parse) ?? .identity
                let ctm = stack.last! * own
                stack.append(ctm)
                if let id = attrs["id"], elements[id] == nil {
                    elements[id] = Element(name: name, attrs: attrs, ctm: ctm)
                }
            }
            depth += 1
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if !stack.isEmpty { stack.removeLast() }
            depth -= 1
        }
    }
}
