import CoreGraphics
import Foundation
import ImageIO
import InkEngine
import PartsKit
import SketchCore
import SwiftDraw
import UniformTypeIdentifiers

enum XMLEscape {
    static func string(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
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
}

/// Locale-independent number text: at most 3 decimals, trailing zeros trimmed.
enum SVGNumber {
    static func format(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        let scaled = (abs(v) * 1000).rounded()
        guard scaled > 0, scaled < 9e15 else { return "0" }
        let n = Int64(scaled)
        let whole = n / 1000, frac = n % 1000
        var s = v < 0 ? "-" : ""
        s += String(whole)
        if frac != 0 {
            var f = String(frac)
            f = String(repeating: "0", count: 3 - f.count) + f
            while f.hasSuffix("0") { f.removeLast() }
            s += "." + f
        }
        return s
    }
}

/// Vector SVG of an `ExportContent`; mirrors `SceneDrawer` so SVG matches PNG/PDF.
public enum SVGWriter {
    static let inkPixelSize = 0.02

    public static func svg(_ content: ExportContent) -> Data {
        let b = content.bounds
        let n = SVGNumber.format
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(n(b.size.x))mm\" height=\"\(n(b.size.y))mm\" "
        out += "viewBox=\"\(n(b.minX)) \(n(b.minY)) \(n(b.size.x)) \(n(b.size.y))\">\n"
        for object in content.objects {
            switch object {
            case .ink(let s): out += ink(s)
            case .shape(let s): out += shape(s)
            case .text(let t): out += text(t)
            case .image(let i): out += image(i, content.document)
            case .wire(let w): out += wire(w)
            case .part(let p): out += part(p, content.document)
            }
        }
        out += "</svg>\n"
        return Data(out.utf8)
    }

    // MARK: Helpers

    private static func n(_ v: Double) -> String { SVGNumber.format(v) }

    private static func hex(_ c: RGBAColor) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return "#" + [c.r, c.g, c.b].map { b in
            let s = String(byte(b), radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
    }

    private static func fill(_ c: RGBAColor) -> String {
        var s = " fill=\"\(hex(c))\""
        if c.a < 1 { s += " fill-opacity=\"\(n(c.a))\"" }
        return s
    }

    private static func stroke(_ c: RGBAColor) -> String {
        var s = " stroke=\"\(hex(c))\""
        if c.a < 1 { s += " stroke-opacity=\"\(n(c.a))\"" }
        return s
    }

    private static func strokeStyle(width: Double, color: RGBAColor) -> String {
        stroke(color) + " stroke-width=\"\(n(width))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
    }

    private static func pt(_ p: Vec2) -> String { "\(n(p.x)) \(n(p.y))" }
    private static func deg(_ rad: Double) -> String { n(rad * 180 / .pi) }

    // MARK: Objects

    private static func ink(_ s: InkStroke) -> String {
        let poly = StrokeOutline.polygon(s.points, baseWidth: s.baseWidth, tool: s.tool, pixelSize: inkPixelSize)
        guard let first = poly.first else { return "" }
        var d = "M\(pt(first))"
        for p in poly.dropFirst() { d += "L\(pt(p))" }
        d += "Z"
        var extra = ""
        if s.tool == .highlighter {
            extra = " opacity=\"\(n(SceneDrawer.highlighterAlpha))\" style=\"mix-blend-mode:multiply\""
        }
        return "<path d=\"\(d)\"\(fill(s.color))\(extra)/>\n"
    }

    private static func shape(_ s: ShapeObject) -> String {
        let style = strokeStyle(width: s.lineWidth, color: s.strokeColor)
        switch s.kind {
        case .line:
            return "<line x1=\"\(n(s.start.x))\" y1=\"\(n(s.start.y))\" x2=\"\(n(s.end.x))\" y2=\"\(n(s.end.y))\" fill=\"none\"\(style)/>\n"
        case .arrow:
            var d = "M\(pt(s.start))L\(pt(s.end))"
            if let (b1, b2) = ShapeGeometry.arrowBarbs(of: s) {
                for barb in [b1, b2] { d += "M\(pt(s.end))L\(pt(barb))" }
            }
            return "<path d=\"\(d)\" fill=\"none\"\(style)/>\n"
        case .rectangle, .ellipse:
            let r = ShapeGeometry.rect(of: s)
            let fillAttr = s.fillColor.map(fill) ?? " fill=\"none\""
            if s.kind == .rectangle {
                return "<rect x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.size.x))\" height=\"\(n(r.size.y))\"\(fillAttr)\(style)/>\n"
            }
            return "<ellipse cx=\"\(n(r.minX + r.size.x / 2))\" cy=\"\(n(r.minY + r.size.y / 2))\" rx=\"\(n(r.size.x / 2))\" ry=\"\(n(r.size.y / 2))\"\(fillAttr)\(style)/>\n"
        }
    }

    private static func wire(_ w: Wire) -> String {
        let pts = w.polyline.map(pt).joined(separator: " ")
        let style = strokeStyle(width: w.width, color: w.color)
        var out = "<g>\n<polyline points=\"\(pts)\" fill=\"none\"\(style)/>\n"
        for end in [w.start, w.end] where end.attachment == nil {
            out += "<circle cx=\"\(n(end.position.x))\" cy=\"\(n(end.position.y))\" r=\"\(n(Wire.freeEndRadius))\" fill=\"none\"\(style)/>\n"
        }
        return out + "</g>\n"
    }

    private static func text(_ t: TextObject) -> String {
        guard t.fontSize > 0 else { return "" }
        var out = "<text font-family=\"Helvetica, Arial, sans-serif\" font-size=\"\(n(t.fontSize))\"\(fill(t.color)) xml:space=\"preserve\""
        if t.rotation != 0 { out += " transform=\"rotate(\(deg(t.rotation)) \(pt(t.position)))\"" }
        out += ">"
        for line in TextLayout.lines(t) where !line.text.isEmpty {
            out += "<tspan x=\"\(n(t.position.x))\" y=\"\(n(t.position.y + line.baselineY))\">\(XMLEscape.string(line.text))</tspan>"
        }
        return out + "</text>\n"
    }

    private static func image(_ i: ImageObject, _ doc: SketchDocument) -> String {
        let w = i.frame.size.x, h = i.frame.size.y
        guard w > 0, h > 0, let data = doc.assets[i.assetName], let (mime, bytes) = rasterPayload(data) else { return "" }
        var out = "<image x=\"\(n(i.frame.minX))\" y=\"\(n(i.frame.minY))\" width=\"\(n(w))\" height=\"\(n(h))\" preserveAspectRatio=\"none\""
        if i.rotation != 0 {
            out += " transform=\"rotate(\(deg(i.rotation)) \(n(i.frame.minX + w / 2)) \(n(i.frame.minY + h / 2)))\""
        }
        return out + " href=\"\(dataURI(mime, bytes))\"/>\n"
    }

    private static func part(_ p: PartInstance, _ doc: SketchDocument) -> String {
        guard let def = doc.parts[p.definitionKey], let (mime, bytes) = partPayload(def, doc) else { return placeholder(p) }
        let w = def.size.x, h = def.size.y
        let turns = ((p.quarterTurns % 4) + 4) % 4
        var out = "<g>\n<g transform=\"translate(\(pt(p.center))) rotate(\(turns * 90)) translate(\(n(-w / 2)) \(n(-h / 2)))\">"
        out += "<image width=\"\(n(w))\" height=\"\(n(h))\" href=\"\(dataURI(mime, bytes))\"/></g>\n"
        for c in def.connectors {
            guard let spec = c.leg, let seg = p.legSegment(for: c, in: def) else { continue }
            out += "<line x1=\"\(n(seg.origin.x))\" y1=\"\(n(seg.origin.y))\" x2=\"\(n(seg.end.x))\" y2=\"\(n(seg.end.y))\" fill=\"none\""
            out += "\(stroke(spec.color)) stroke-width=\"\(n(spec.width))\" stroke-linecap=\"round\"/>\n"
        }
        return out + "</g>\n"
    }

    /// Same conditions as `SceneDrawer.drawPart` for a drawable graphic.
    private static func partPayload(_ def: PartDefinition, _ doc: SketchDocument) -> (String, Data)? {
        guard def.size.x > 0, def.size.y > 0, let data = doc.assets[def.graphicAsset] else { return nil }
        switch def.graphicKind {
        case .svg:
            guard PartInputGuard.isAcceptableSVG(data), SVG(data: data) != nil else { return nil }
            return ("image/svg+xml", data)
        case .png:
            guard ImageDecoding.cgImage(data) != nil else { return nil }
            return ("image/png", data)
        }
    }

    private static func placeholder(_ p: PartInstance) -> String {
        let side = SceneDrawer.placeholderSide, lw = 0.4
        return "<rect x=\"\(n(p.center.x - side / 2))\" y=\"\(n(p.center.y - side / 2))\" width=\"\(n(side))\" height=\"\(n(side))\" fill=\"none\" stroke=\"#666666\" stroke-width=\"\(n(lw))\" stroke-dasharray=\"\(n(lw * 4)) \(n(lw * 3))\"/>\n"
    }

    // MARK: Image payloads

    private static func dataURI(_ mime: String, _ data: Data) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// PNG and JPEG pass through; anything else decodable is transcoded to PNG.
    private static func rasterPayload(_ data: Data) -> (String, Data)? {
        let b = [UInt8](data.prefix(4))
        if b == [0x89, 0x50, 0x4E, 0x47] { return ("image/png", data) }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return ("image/jpeg", data) }
        guard let img = ImageDecoding.cgImage(data) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return ("image/png", out as Data)
    }
}
