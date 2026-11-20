import SketchCore

struct Fix {
    var doc = SketchDocument()
    let res = PartDefinition.fixtureResistor()
    let board = PartDefinition.fixtureBreadboardMini()
    let module = PartDefinition.fixtureModule()

    init() { for d in [res, board, module] { doc.parts[d.key] = d } }

    @discardableResult
    mutating func add(_ d: PartDefinition, at c: Vec2 = .zero, label: String = "", properties: [String: String] = [:],
                      rotation: Double = 0, legEnds: [String: Vec2] = [:]) -> ObjectID {
        let p = PartInstance(definitionKey: d.key, center: c, rotation: rotation, label: label,
                             properties: properties, legEnds: legEnds)
        doc.objects.append(.part(p))
        return p.id
    }

    @discardableResult
    mutating func wire(_ a: (ObjectID, String)?, _ b: (ObjectID, String)?) -> ObjectID {
        func end(_ x: (ObjectID, String)?) -> WireEnd {
            WireEnd(position: .zero, attachment: x.map { .connector(part: $0.0, connector: $0.1) })
        }
        let w = Wire(start: end(a), end: end(b))
        doc.objects.append(.wire(w))
        return w.id
    }
}

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import ExportKit

/// Renders `content` into a white RGBA bitmap; CTM maps `content.bounds` (mm, y-down) at `pxPerMM`.
func render(_ content: ExportContent, pxPerMM: Double) -> CGImage {
    let w = Int((content.bounds.size.x * pxPerMM).rounded(.up)), h = Int((content.bounds.size.y * pxPerMM).rounded(.up))
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: 0, y: Double(h))
    ctx.scaleBy(x: pxPerMM, y: -pxPerMM)
    ctx.translateBy(x: -content.bounds.minX, y: -content.bounds.minY)
    SceneDrawer.draw(content, in: ctx, pixelSize: 1 / pxPerMM)
    return ctx.makeImage()!
}

func pixel(_ img: CGImage, mmX: Double, mmY: Double, bounds: Rect, pxPerMM: Double) -> (r: Double, g: Double, b: Double, a: Double) {
    let x = Int(((mmX - bounds.minX) * pxPerMM).rounded(.down)), y = Int(((mmY - bounds.minY) * pxPerMM).rounded(.down))
    let data = img.dataProvider!.data! as Data
    let o = y * img.bytesPerRow + x * 4
    return (Double(data[o]) / 255, Double(data[o + 1]) / 255, Double(data[o + 2]) / 255, Double(data[o + 3]) / 255)
}

/// 2x1 PNG: left px red, right px blue.
func twoPixelPNG() -> Data {
    let ctx = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}
