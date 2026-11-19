import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import SketchCore
@testable import ExportKit

private let red = RGBAColor(r: 1, g: 0, b: 0)

/// 100x50 mm filled red rect at (0,0)-(100,50); content bounds with 5 mm margin = 110x60.
private func rectContent() throws -> ExportContent {
    var doc = SketchDocument()
    doc.objects = [.shape(ShapeObject(kind: .rectangle, start: Vec2(x: 0, y: 0), end: Vec2(x: 100, y: 50),
                                      strokeColor: red, fillColor: red, lineWidth: 0.5))]
    // Explicit bounds: exactly 100x50 plus 5 mm margin (make() would also count the stroke width).
    return ExportContent(document: doc, objects: doc.objects, bounds: Rect(origin: Vec2(x: -5, y: -5), size: Vec2(x: 110, y: 60)))
}

private func decode(_ data: Data) throws -> CGImage {
    let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
}

private func rgba(_ img: CGImage, _ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let o = (y * w + x) * 4  // CG bitmap row 0 = top
    return (Double(buf[o]) / 255, Double(buf[o + 1]) / 255, Double(buf[o + 2]) / 255, Double(buf[o + 3]) / 255)
}

@Test func pngSizeFollowsDPI() throws {
    let c = try rectContent()
    let r = try RasterExporter.png(c, options: PNGOptions(dpi: 254))
    #expect(r.width == 1100 && r.height == 600)
    #expect(r.effectiveDPI == 254)
    let img = try decode(r.data)
    #expect(img.width == 1100 && img.height == 600)
    let src = try #require(CGImageSourceCreateWithData(r.data as CFData, nil))
    let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    let dpiW = try #require(props[kCGImagePropertyDPIWidth] as? Double)
    #expect(abs(dpiW - 254) < 0.5)
}

@Test func pngBackgrounds() throws {
    let c = try rectContent()
    let white = try decode(RasterExporter.png(c, options: PNGOptions(dpi: 50, background: .white)).data)
    let w = rgba(white, 1, 1)
    #expect(w.0 == 1 && w.1 == 1 && w.2 == 1 && w.3 == 1)
    let clear = try decode(RasterExporter.png(c, options: PNGOptions(dpi: 50, background: .transparent)).data)
    #expect(rgba(clear, 1, 1).3 == 0)
    // content still drawn on transparent
    let mid = rgba(clear, clear.width / 2, clear.height / 2)
    #expect(mid.3 > 0.99 && mid.0 > 0.99 && mid.1 < 0.05, "\(mid)")
}

@Test func hugeDrawingReducesDPI() throws {
    var doc = SketchDocument()
    doc.objects = [.shape(ShapeObject(kind: .rectangle, start: Vec2(x: 0, y: 0), end: Vec2(x: 5000, y: 5000), lineWidth: 1))]
    let c = try ExportContent.make(doc, scope: .all)
    let p = try RasterExporter.plan(c, options: PNGOptions(dpi: 600))
    #expect(p.effectiveDPI < 600)
    #expect(p.width <= 16_384 && p.height <= 16_384)
    #expect(p.width * p.height <= 50_000_000)
    // largest-fit: not needlessly small
    #expect(p.effectiveDPI > 0.95 * (50_000_000.0 / (5010.0 * 5010.0)).squareRoot() * 25.4 * 0.99)
}

@Test func absurdSizeThrowsTooLarge() throws {
    var doc = SketchDocument()
    doc.objects = [.shape(ShapeObject(kind: .rectangle, start: Vec2(x: 0, y: 0), end: Vec2(x: 1_000_000, y: 10), lineWidth: 1))]
    let c = try ExportContent.make(doc, scope: .all)
    #expect(throws: ExportError.tooLarge) { try RasterExporter.plan(c, options: PNGOptions(dpi: 600)) }
}

@Test func pdfPageSizeInPoints() throws {
    let data = try PDFExporter.pdf(rectContent())
    let doc = try #require(PDFDocument(data: data))
    #expect(doc.pageCount == 1)
    let box = try #require(doc.page(at: 0)).bounds(for: .mediaBox)
    #expect(abs(box.width - 110 * 72 / 25.4) < 0.01, "\(box)")
    #expect(abs(box.height - 60 * 72 / 25.4) < 0.01)
}

@Test func pdfKeepsTextAsText() throws {
    var doc = SketchDocument()
    doc.objects = [.text(TextObject(text: "Hello FlyingSketch", position: Vec2(x: 0, y: 0), fontSize: 6))]
    let c = try ExportContent.make(doc, scope: .all)
    let pdf = try #require(PDFDocument(data: PDFExporter.pdf(c)))
    #expect(pdf.string?.contains("Hello FlyingSketch") == true)
}

@Test func pdfMatchesPNGLayout() throws {
    // L shape (asymmetric) so a y-flip changes the pixels: bar (0,0)-(100,10), leg (0,10)-(20,40); bounds 110x50 mm.
    var d = SketchDocument()
    d.objects = [(0.0, 0.0, 100.0, 10.0), (0.0, 10.0, 20.0, 40.0)].map {
        .shape(ShapeObject(kind: .rectangle, start: Vec2(x: $0.0, y: $0.1), end: Vec2(x: $0.2, y: $0.3),
                           strokeColor: red, fillColor: red, lineWidth: 0.5))
    }
    let c = ExportContent(document: d, objects: d.objects, bounds: Rect(origin: Vec2(x: -5, y: -5), size: Vec2(x: 110, y: 50)))
    let png = try decode(RasterExporter.png(c, options: PNGOptions(dpi: 254)).data)  // 10 px/mm
    let pdf = try #require(CGPDFDocument(CGDataProvider(data: PDFExporter.pdf(c) as CFData)!))
    let page = try #require(pdf.page(at: 1))
    let w = png.width, h = png.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let box = page.getBoxRect(.mediaBox)
    ctx.scaleBy(x: Double(w) / box.width, y: Double(h) / box.height)  // pt -> px, y not flipped
    ctx.drawPDFPage(page)
    let pdfImg = ctx.makeImage()!
    // px = (mm + 5) * 10: bar interior, leg interior, empty area right of leg (white; red if y were flipped)
    for (px, py) in [(650, 100), (150, 350), (650, 350), (10, 10)] {
        let a = rgba(png, px, py), b = rgba(pdfImg, px, py)
        #expect(abs(a.0 - b.0) < 0.06 && abs(a.1 - b.1) < 0.06 && abs(a.2 - b.2) < 0.06)
    }
    #expect(rgba(pdfImg, 650, 100).1 < 0.1)  // red in bar
    #expect(rgba(pdfImg, 150, 350).1 < 0.1)  // red in leg
    #expect(rgba(pdfImg, 650, 350).1 > 0.9)  // white
}
