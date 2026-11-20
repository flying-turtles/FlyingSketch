import CoreGraphics
import Foundation
import Testing
import SketchCore
@testable import ExportKit

private func make(_ objects: [SceneObject], doc: SketchDocument = SketchDocument(),
                  bounds: Rect = Rect(origin: Vec2(x: -5, y: -5), size: Vec2(x: 110, y: 60))) -> ExportContent {
    var d = doc
    d.objects = objects
    return ExportContent(document: d, objects: objects, bounds: bounds)
}

private func svgString(_ c: ExportContent) -> String { String(decoding: SVGWriter.svg(c), as: UTF8.self) }

private func ink(_ a: Vec2, _ b: Vec2, tool: InkTool = .pen, color: RGBAColor = .black) -> SceneObject {
    .ink(InkStroke(points: [InkPoint(position: a, pressure: 1, time: 0), InkPoint(position: b, pressure: 1, time: 0.1)],
                   tool: tool, color: color, baseWidth: 2))
}

/// Minimal DOM: records root children names and text of all tspans.
private final class Probe: NSObject, XMLParserDelegate {
    var depth = 0
    var rootAttrs: [String: String] = [:]
    var rootChildren: [String] = []
    var tspanText: [String] = []
    var attrsByName: [String: [[String: String]]] = [:]
    private var inTspan = false
    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String]) {
        if depth == 0 { rootAttrs = a } else if depth == 1 { rootChildren.append(name) }
        attrsByName[name, default: []].append(a)
        if name == "tspan" { inTspan = true; tspanText.append("") }
        depth += 1
    }
    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
        if name == "tspan" { inTspan = false }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { if inTspan { tspanText[tspanText.count - 1] += s } }
}

private func probe(_ data: Data) throws -> Probe {
    let parser = XMLParser(data: data)
    let p = Probe()
    parser.delegate = p
    #expect(parser.parse(), "XML parse error: \(String(describing: parser.parserError))")
    return p
}

@Test func svgRootUsesMillimetres() throws {
    let data = SVGWriter.svg(make([ink(.zero, Vec2(x: 100, y: 50))]))
    #expect(String(decoding: data, as: UTF8.self).hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
    let p = try probe(data)
    #expect(p.rootAttrs["width"] == "110mm")
    #expect(p.rootAttrs["height"] == "60mm")
    #expect(p.rootAttrs["viewBox"] == "-5 -5 110 60")
}

@Test func oneChildPerObjectInZOrder() throws {
    var f = Fix()
    let svgAsset = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10mm\" height=\"4mm\" viewBox=\"0 0 10 4\"><rect width=\"10\" height=\"4\"/></svg>".utf8)
    var def = f.res
    def.size = Vec2(x: 10, y: 4)
    f.doc.parts[def.key] = def
    f.doc.assets[def.graphicAsset] = svgAsset
    f.doc.assets["a.png"] = twoPixelPNG()
    let part = PartInstance(definitionKey: def.key, center: Vec2(x: 50, y: 25))
    let objs: [SceneObject] = [
        ink(Vec2(x: 0, y: 0), Vec2(x: 10, y: 0)),
        .shape(ShapeObject(kind: .line, start: .zero, end: Vec2(x: 5, y: 5))),
        .shape(ShapeObject(kind: .arrow, start: .zero, end: Vec2(x: 5, y: 5))),
        .shape(ShapeObject(kind: .rectangle, start: .zero, end: Vec2(x: 5, y: 5), fillColor: .black)),
        .shape(ShapeObject(kind: .ellipse, start: .zero, end: Vec2(x: 5, y: 5))),
        .text(TextObject(text: "a\nb", position: .zero)),
        .image(ImageObject(assetName: "a.png", frame: Rect(origin: .zero, size: Vec2(x: 4, y: 2)))),
        .part(part),
        .wire(Wire(start: WireEnd(position: .zero), end: WireEnd(position: Vec2(x: 9, y: 9)))),
    ]
    let p = try probe(SVGWriter.svg(make(objs, doc: f.doc)))
    #expect(p.rootChildren == ["path", "line", "path", "rect", "ellipse", "text", "image", "g", "g"])
    #expect(p.tspanText == ["a", "b"])
    #expect(p.attrsByName["polyline"]?.first?["fill"] == "none")
    #expect(p.attrsByName["circle"]?.count == 2)
    #expect(p.attrsByName["rect"]?.first?["fill"] == "#000000")
}

@Test func textIsEscaped() throws {
    let t = TextObject(text: "a<b & \"c\"", position: .zero)
    let data = SVGWriter.svg(make([.text(t)]))
    let p = try probe(data)
    #expect(p.tspanText.joined() == "a<b & \"c\"")
    let s = String(decoding: data, as: UTF8.self)
    #expect(s.contains("a&lt;b &amp; &quot;c&quot;") || s.contains("a&lt;b &amp; \"c\""))
    #expect(!s.contains("a<b"))
}

@Test func partsEmbedDataURI() throws {
    var f = Fix()
    var def = f.res
    def.size = Vec2(x: 10, y: 4)
    let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10mm\" height=\"4mm\" viewBox=\"0 0 10 4\"><rect width=\"10\" height=\"4\"/></svg>".utf8)
    f.doc.parts[def.key] = def
    f.doc.assets[def.graphicAsset] = svg
    let part = PartInstance(definitionKey: def.key, center: Vec2(x: 20, y: 20), rotation: .pi / 2)
    let p = try probe(SVGWriter.svg(make([.part(part)], doc: f.doc)))
    let href = try #require(p.attrsByName["image"]?.first?["href"])
    let prefix = "data:image/svg+xml;base64,"
    #expect(href.hasPrefix(prefix))
    #expect(Data(base64Encoded: String(href.dropFirst(prefix.count))) == svg)
    #expect(p.attrsByName["image"]?.first?["width"] == "10")
    #expect(p.attrsByName["image"]?.first?["height"] == "4")
    #expect(p.attrsByName["image"]?.first?["preserveAspectRatio"] == "none")
    #expect(p.attrsByName["g"]?.contains { $0["transform"] == "translate(20 20) rotate(90) translate(-5 -2)" } == true)

    // PNG part.
    var f2 = Fix()
    var d2 = f2.res
    d2.size = Vec2(x: 10, y: 4)
    d2.graphicKind = .png
    f2.doc.parts[d2.key] = d2
    let png = twoPixelPNG()
    f2.doc.assets[d2.graphicAsset] = png
    let p2 = try probe(SVGWriter.svg(make([.part(PartInstance(definitionKey: d2.key, center: .zero))], doc: f2.doc)))
    let h2 = try #require(p2.attrsByName["image"]?.first?["href"])
    #expect(h2.hasPrefix("data:image/png;base64,"))
    #expect(Data(base64Encoded: String(h2.dropFirst("data:image/png;base64,".count))) == png)
}

@Test func brokenPartBecomesPlaceholderAndLegsFollowBody() throws {
    var doc = SketchDocument()
    let missing = PartInstance(definitionKey: "nope@v1", center: Vec2(x: 20, y: 20))
    doc.objects = [.part(missing)]
    let p = try probe(SVGWriter.svg(make([.part(missing)], doc: doc)))
    #expect(p.rootChildren == ["rect"])
    let r = try #require(p.attrsByName["rect"]?.first)
    #expect(r["stroke-dasharray"] != nil)
    #expect(r["width"] == "10")
    #expect(r["x"] == "15")
    #expect(r["fill"] == "none")

    // Invalid SVG asset -> placeholder too.
    var f = Fix()
    var def = f.res
    def.size = Vec2(x: 10, y: 4)
    f.doc.parts[def.key] = def
    f.doc.assets[def.graphicAsset] = Data("not svg".utf8)
    let p2 = try probe(SVGWriter.svg(make([.part(PartInstance(definitionKey: def.key, center: .zero))], doc: f.doc)))
    // Placeholder plus legs (the canvas still draws legs for a broken graphic).
    #expect(p2.rootChildren == ["g"])
    #expect(p2.attrsByName["rect"]?.count == 1)
    #expect(p2.attrsByName["line"]?.isEmpty == false)

    // Legs: lines after the body, outside the transformed g.
    var f3 = Fix()
    var d3 = f3.res
    d3.size = Vec2(x: 10, y: 4)
    f3.doc.parts[d3.key] = d3
    f3.doc.assets[d3.graphicAsset] = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10mm\" height=\"4mm\" viewBox=\"0 0 10 4\"><rect width=\"10\" height=\"4\"/></svg>".utf8)
    let inst = PartInstance(definitionKey: d3.key, center: Vec2(x: 20, y: 20), legEnds: ["a": Vec2(x: 20, y: 35)])
    let p3 = try probe(SVGWriter.svg(make([.part(inst)], doc: f3.doc)))
    #expect(p3.rootChildren == ["g"])
    #expect(p3.attrsByName["line"]?.contains { $0["x2"] == "20" && $0["y2"] == "35" } == true)
}

@Test func highlighterUsesMultiply() throws {
    let p = try probe(SVGWriter.svg(make([ink(.zero, Vec2(x: 10, y: 0), tool: .highlighter, color: RGBAColor(r: 1, g: 1, b: 0))])))
    let a = try #require(p.attrsByName["path"]?.first)
    #expect(a["opacity"] == "0.35")
    #expect(a["style"] == "mix-blend-mode:multiply")
    #expect(a["fill"] == "#ffff00")
    let pen = try probe(SVGWriter.svg(make([ink(.zero, Vec2(x: 10, y: 0))])))
    #expect(pen.attrsByName["path"]?.first?["opacity"] == nil)
    #expect(pen.attrsByName["path"]?.first?["style"] == nil)
}

@Test func numbersArePOSIX() throws {
    let s = ShapeObject(kind: .line, start: Vec2(x: 1.5, y: 1.0 / 3.0), end: Vec2(x: -5, y: 0.125), lineWidth: 0.5)
    let svg = svgString(make([.shape(s)]))
    #expect(svg.contains("x1=\"1.5\""))
    #expect(svg.contains("y1=\"0.333\""))
    #expect(svg.contains("x2=\"-5\""))
    #expect(svg.contains("y2=\"0.125\""))
    #expect(!svg.contains("1,5"))
    #expect(SVGNumber.format(0.0004) == "0")
    #expect(SVGNumber.format(-0.0004) == "0")
    #expect(SVGNumber.format(2.0) == "2")
}

@Test func colourAlphaAddsOpacityAndImagesTranscode() throws {
    let s = ShapeObject(kind: .rectangle, start: .zero, end: Vec2(x: 5, y: 5), strokeColor: RGBAColor(r: 1, g: 0, b: 0, a: 0.5),
                        fillColor: RGBAColor(r: 0, g: 0, b: 1, a: 0.25), lineWidth: 1)
    let p = try probe(SVGWriter.svg(make([.shape(s)])))
    let r = try #require(p.attrsByName["rect"]?.first)
    #expect(r["stroke"] == "#ff0000")
    #expect(r["stroke-opacity"] == "0.5")
    #expect(r["fill"] == "#0000ff")
    #expect(r["fill-opacity"] == "0.25")

    // TIFF asset is transcoded to PNG; garbage and missing assets are omitted.
    let tiff = tiffBytes()
    var doc = SketchDocument()
    doc.assets["t.tiff"] = tiff
    doc.assets["g.bin"] = Data([1, 2, 3])
    doc.assets["p.png"] = twoPixelPNG()
    let frame = Rect(origin: .zero, size: Vec2(x: 4, y: 2))
    let objs: [SceneObject] = [.image(ImageObject(assetName: "t.tiff", frame: frame)),
                               .image(ImageObject(assetName: "g.bin", frame: frame)),
                               .image(ImageObject(assetName: "nope", frame: frame)),
                               .image(ImageObject(assetName: "p.png", frame: frame, rotation: .pi / 2))]
    let q = try probe(SVGWriter.svg(make(objs, doc: doc)))
    let imgs = try #require(q.attrsByName["image"])
    #expect(imgs.count == 2)
    #expect(imgs[0]["href"]?.hasPrefix("data:image/png;base64,") == true)
    #expect(imgs[1]["transform"] == "rotate(90 2 1)")
    #expect(imgs[1]["preserveAspectRatio"] == "none")
}

import ImageIO
import UniformTypeIdentifiers
private func tiffBytes() -> Data {
    let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

@Test func pngKindPartWithJPEGBytesIsLabelledJPEG() throws {
    var f = Fix()
    var d = f.res
    d.size = Vec2(x: 10, y: 4)
    d.graphicKind = .png
    f.doc.parts[d.key] = d
    let jpeg = jpegBytes()
    f.doc.assets[d.graphicAsset] = jpeg
    let p = try probe(SVGWriter.svg(make([.part(PartInstance(definitionKey: d.key, center: .zero))], doc: f.doc)))
    let img = try #require(p.attrsByName["image"]?.first)
    let href = try #require(img["href"])
    #expect(href.hasPrefix("data:image/jpeg;base64,"))
    #expect(Data(base64Encoded: String(href.dropFirst("data:image/jpeg;base64,".count))) == jpeg)
    #expect(img["preserveAspectRatio"] == "none")

    // TIFF bytes in a .png part are transcoded to real PNG.
    f.doc.assets[d.graphicAsset] = tiffBytes()
    let q = try probe(SVGWriter.svg(make([.part(PartInstance(definitionKey: d.key, center: .zero))], doc: f.doc)))
    let h2 = try #require(q.attrsByName["image"]?.first?["href"])
    #expect(h2.hasPrefix("data:image/png;base64,"))
    let raw = try #require(Data(base64Encoded: String(h2.dropFirst("data:image/png;base64,".count))))
    #expect([UInt8](raw.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
}

private func jpegBytes() -> Data {
    let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

@Test func controlCharactersAreDroppedFromText() throws {
    let t = TextObject(text: "a\u{1}b\u{0}c\u{8}d\te", position: .zero, fontSize: 5)
    let p = try probe(SVGWriter.svg(make([.text(t)])))
    #expect(p.tspanText == ["abcd\te"])
}

@Test func rotatedShapeCarriesTransform() throws {
    func shape(_ kind: ShapeKind, _ r: Double) -> SceneObject {
        .shape(ShapeObject(kind: kind, start: .zero, end: Vec2(x: 20, y: 4), rotation: r))
    }
    let q = try probe(SVGWriter.svg(make([shape(.rectangle, .pi / 2), shape(.ellipse, .pi / 2),
                                          shape(.rectangle, 0), shape(.line, 1)])))
    #expect(try #require(q.attrsByName["rect"])[0]["transform"] == "rotate(90 10 2)")
    #expect(try #require(q.attrsByName["rect"])[1]["transform"] == nil)
    #expect(try #require(q.attrsByName["ellipse"])[0]["transform"] == "rotate(90 10 2)")
    #expect(try #require(q.attrsByName["line"])[0]["transform"] == nil)
}

@Test func rotatedShapeTransformIsClockwiseThirtyDegrees() throws {
    let r = SceneObject.shape(ShapeObject(kind: .rectangle, start: .zero, end: Vec2(x: 20, y: 4), rotation: .pi / 6))
    let q = try probe(SVGWriter.svg(make([r])))
    #expect(try #require(q.attrsByName["rect"])[0]["transform"] == "rotate(30 10 2)")
}
