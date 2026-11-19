import CoreGraphics
import CoreText
import Foundation
import InkEngine
import SketchCore

/// Draws scene objects into a context whose CTM is 1 unit = 1 mm, y-down, origin at world (0, 0).
public enum SceneDrawer {
    static let highlighterAlpha = 0.35

    static func draw(_ content: ExportContent, in ctx: CGContext, pixelSize: Double) {
        var images: [String: CGImage?] = [:]
        for object in content.objects {
            ctx.saveGState()
            switch object {
            case .ink(let s): drawInk(s, ctx, pixelSize)
            case .shape(let s): drawShape(s, ctx)
            case .text(let t): drawText(t, ctx)
            case .image(let i):
                if images[i.assetName] == nil {
                    images[i.assetName] = content.document.assets[i.assetName].flatMap(ImageDecoding.cgImage)
                }
                if let img = images[i.assetName] ?? nil { drawImage(i, img, ctx) }
            case .wire(let w): drawWire(w, ctx)
            case .part: break  // Task 4
            }
            ctx.restoreGState()
        }
    }

    private static func cg(_ c: RGBAColor) -> CGColor { CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a) }
    private static func cgp(_ v: Vec2) -> CGPoint { CGPoint(x: v.x, y: v.y) }

    private static func drawInk(_ s: InkStroke, _ ctx: CGContext, _ pixelSize: Double) {
        let poly = StrokeOutline.polygon(s.points, baseWidth: s.baseWidth, tool: s.tool, pixelSize: pixelSize)
        guard let first = poly.first else { return }
        let path = CGMutablePath()
        path.move(to: cgp(first))
        for p in poly.dropFirst() { path.addLine(to: cgp(p)) }
        path.closeSubpath()
        if s.tool == .highlighter {
            ctx.setAlpha(highlighterAlpha)
            ctx.setBlendMode(.multiply)
        }
        ctx.setFillColor(cg(s.color))
        ctx.addPath(path)
        ctx.fillPath(using: .winding)
    }

    private static func drawShape(_ s: ShapeObject, _ ctx: CGContext) {
        let r = ShapeGeometry.rect(of: s)
        let rect = CGRect(x: r.minX, y: r.minY, width: r.size.x, height: r.size.y)
        let path = CGMutablePath()
        switch s.kind {
        case .line, .arrow:
            path.move(to: cgp(s.start))
            path.addLine(to: cgp(s.end))
            if let (b1, b2) = ShapeGeometry.arrowBarbs(of: s) {
                for barb in [b1, b2] {
                    path.move(to: cgp(s.end))
                    path.addLine(to: cgp(barb))
                }
            }
        case .rectangle: path.addRect(rect)
        case .ellipse: path.addEllipse(in: rect)
        }
        ctx.setLineWidth(s.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if (s.kind == .rectangle || s.kind == .ellipse), let fill = s.fillColor {
            ctx.setFillColor(cg(fill))
            ctx.addPath(path)
            ctx.fillPath()
        }
        ctx.setStrokeColor(cg(s.strokeColor))
        ctx.addPath(path)
        ctx.strokePath()
    }

    private static func drawWire(_ w: Wire, _ ctx: CGContext) {
        let pts = w.polyline.map(cgp)
        let path = CGMutablePath()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.addLine(to: p) }
        let r = Wire.freeEndRadius
        for end in [w.start, w.end] where end.attachment == nil {
            path.addEllipse(in: CGRect(x: end.position.x - r, y: end.position.y - r, width: r * 2, height: r * 2))
        }
        ctx.setLineWidth(w.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(cg(w.color))
        ctx.addPath(path)
        ctx.strokePath()
    }

    private static func drawText(_ t: TextObject, _ ctx: CGContext) {
        guard t.fontSize > 0 else { return }
        let font = TextLayout.font(size: t.fontSize)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: cg(t.color)]
        ctx.translateBy(x: t.position.x, y: t.position.y)
        ctx.rotate(by: t.rotation)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for line in TextLayout.lines(t) where !line.text.isEmpty {
            let attributed = CFAttributedStringCreate(nil, line.text as CFString, attrs as CFDictionary)!
            let ctLine = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: 0, y: line.baselineY)
            CTLineDraw(ctLine, ctx)
        }
    }

    private static func drawImage(_ i: ImageObject, _ img: CGImage, _ ctx: CGContext) {
        let w = i.frame.size.x, h = i.frame.size.y
        guard w > 0, h > 0 else { return }
        ctx.translateBy(x: i.frame.minX + w / 2, y: i.frame.minY + h / 2)
        ctx.rotate(by: i.rotation)
        ctx.translateBy(x: -w / 2, y: h / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
}
