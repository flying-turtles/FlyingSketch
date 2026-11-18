import QuartzCore
import UIKit
import Testing
import SketchCore
@testable import CanvasUI

private let viewSize = Vec2(x: 1024, y: 1366)
private let ppm = Viewport.pointsPerMillimetre

private func svgData(_ w: Double, _ h: Double) -> Data {
    Data("""
    <svg xmlns="http://www.w3.org/2000/svg" width="\(w)mm" height="\(h)mm" viewBox="0 0 \(w) \(h)">
    <rect width="\(w)" height="\(h)" fill="red"/></svg>
    """.utf8)
}

private func definition(_ w: Double, _ h: Double, asset: String = "p.svg", legs: Bool = false) -> PartDefinition {
    var connectors: [ConnectorDef] = []
    if legs {
        let pos = Vec2(x: 0, y: h / 2)
        connectors = [ConnectorDef(id: "a", name: "a", kind: .male, position: pos,
                                   leg: LegSpec(origin: pos, defaultEnd: Vec2(x: -5, y: h / 2), color: .black))]
    }
    return PartDefinition(libraryID: "t-\(asset)", versionHash: "1", title: "T", size: Vec2(x: w, y: h),
                          graphicAsset: asset, graphicKind: .svg, connectors: connectors)
}

private func doc(_ def: PartDefinition, turns: Int = 0) -> (SketchDocument, PartInstance) {
    let inst = PartInstance(definitionKey: def.key, center: .zero, quarterTurns: turns, label: "U1")
    return (SketchDocument(objects: [.part(inst)], assets: [def.graphicAsset: svgData(def.size.x, def.size.y)],
                           parts: [def.key: def]), inst)
}

@MainActor private func render(_ d: SketchDocument, zoom: Double, factory: CALayerObjectFactory = CALayerObjectFactory())
    -> (SceneRenderer, CALayer, CALayerObjectFactory) {
    let root = CALayer()
    let r = SceneRenderer(rootLayer: root, factory: factory)
    r.update(document: d, viewport: Viewport(center: .zero, zoom: zoom), viewSize: viewSize, settled: true)
    return (r, root, factory)
}

/// root -> content -> [grid, objects]
@MainActor private func objectsLayer(_ root: CALayer) -> CALayer { root.sublayers![0].sublayers![1] }

@Test @MainActor func partLayerSizedInView() {
    let (d, _) = doc(definition(20, 10))
    let (_, root, _) = render(d, zoom: 2)
    let part = objectsLayer(root).sublayers!.first as! PartLayer
    #expect(abs(part.body.bounds.width - 20 * ppm * 2) < 0.5)
    #expect(abs(part.body.bounds.height - 10 * ppm * 2) < 0.5)
    #expect(abs(part.body.position.x - viewSize.x / 2) < 0.5)
}

@Test @MainActor func rasterScaleCapped() async {
    let (d, _) = doc(definition(200, 100))
    let (_, root, factory) = render(d, zoom: 32)
    let part = objectsLayer(root).sublayers!.first as! PartLayer
    #expect(part.rasterPixelSize.width <= 4096 && part.rasterPixelSize.height <= 4096)
    #expect(part.rasterPixelSize.width > 1000)
    await factory.waitForRasters()
    let image = part.body.contents as! CGImage
    #expect(image.width <= 4096 && image.height <= 4096)
    #expect(image.width == Int(part.rasterPixelSize.width))
}

@Test @MainActor func rotatedPartSwapsExtent() {
    let (d, _) = doc(definition(20, 10), turns: 1)
    let (_, root, _) = render(d, zoom: 1)
    let part = objectsLayer(root).sublayers!.first as! PartLayer
    #expect(abs(part.body.frame.width - 10 * ppm) < 0.5)
    #expect(abs(part.body.frame.height - 20 * ppm) < 0.5)
}

@Test @MainActor func legsDrawnInViewCoordinatesAboveBody() {
    let def = definition(20, 10, legs: true)
    var (d, inst) = doc(def, turns: 2)
    inst.legEnds = ["a": Vec2(x: 20, y: 0)]
    d.objects = [.part(inst)]
    let (_, root, _) = render(d, zoom: 1)
    let part = objectsLayer(root).sublayers!.first as! PartLayer
    #expect(part.legLayers.count == 1)
    let leg = part.legLayers[0]
    #expect(leg.lineCap == .round)
    // origin: local (0,5) turned 180 deg about the centre -> world (10, 0); end world (20, 0) -> view x = centre + 20 mm.
    let end = CGPoint(x: viewSize.x / 2 + 20 * ppm, y: viewSize.y / 2)
    #expect(abs(leg.frame.maxX - end.x) < leg.lineWidth + 0.5)
    #expect(part.sublayers!.firstIndex(of: leg)! > part.sublayers!.firstIndex(of: part.body)!)
}

@Test @MainActor func wireLayerPathFollowsBends() {
    let w = Wire(start: WireEnd(position: .zero), end: WireEnd(position: Vec2(x: 20, y: 10)),
                 bends: [Vec2(x: 20, y: 0)])
    let (_, root, _) = render(SketchDocument(objects: [.wire(w)]), zoom: 1)
    let layer = objectsLayer(root).sublayers!.first as! CAShapeLayer
    var points: [CGPoint] = []
    layer.path!.applyWithBlock { e in
        if e.pointee.type == .moveToPoint || e.pointee.type == .addLineToPoint { points.append(e.pointee.points[0]) }
    }
    #expect(points.count >= 3)
    let origin = layer.frame.origin
    let first = CGPoint(x: points[0].x + origin.x, y: points[0].y + origin.y)
    #expect(abs(first.x - viewSize.x / 2) < 0.5 && abs(first.y - viewSize.y / 2) < 0.5)
    let bend = CGPoint(x: points[1].x + origin.x, y: points[1].y + origin.y)
    #expect(abs(bend.x - (viewSize.x / 2 + 20 * ppm)) < 0.5 && abs(bend.y - viewSize.y / 2) < 0.5)
    #expect(abs(layer.lineWidth - 0.65 * ppm) < 0.01)
    #expect(layer.lineJoin == .round && layer.lineCap == .round)
}

@Test @MainActor func freeEndsGetOpenCircleAttachedDoNot() {
    func subpaths(_ w: Wire) -> Int {
        let (_, root, _) = render(SketchDocument(objects: [.wire(w)]), zoom: 1)
        var moves = 0
        (objectsLayer(root).sublayers!.first as! CAShapeLayer).path!.applyWithBlock {
            if $0.pointee.type == .moveToPoint { moves += 1 }
        }
        return moves
    }
    let attach = WireAttachment.connector(part: .new(), connector: "a")
    let free = Wire(start: WireEnd(position: .zero), end: WireEnd(position: Vec2(x: 10, y: 0)))
    let one = Wire(start: WireEnd(position: .zero, attachment: attach), end: WireEnd(position: Vec2(x: 10, y: 0)))
    let none = Wire(start: WireEnd(position: .zero, attachment: attach),
                    end: WireEnd(position: Vec2(x: 10, y: 0), attachment: attach))
    #expect(subpaths(free) == 3 && subpaths(one) == 2 && subpaths(none) == 1)
}

@Test @MainActor func missingDefinitionShowsPlaceholder() {
    let inst = PartInstance(definitionKey: "nope@1", center: .zero, label: "U7")
    let (_, root, _) = render(SketchDocument(objects: [.part(inst)]), zoom: 1)
    let part = objectsLayer(root).sublayers!.first as! PartLayer
    #expect(part.isPlaceholder)
    #expect(part.placeholderShape?.lineDashPattern?.isEmpty == false)
    #expect(abs(part.placeholderShape!.path!.boundingBox.width - 10 * ppm) < 0.5)
    #expect(part.placeholderText?.string as? String == "U7")
}

@Test @MainActor func culledByRealExtentsIncludingLegs() {
    // Body is off the left edge, but a long leg reaches into view.
    let def = definition(20, 10, legs: true)
    var inst = PartInstance(definitionKey: def.key, center: Vec2(x: -400, y: 0))
    inst.legEnds = ["a": Vec2(x: 100, y: 0)]
    let d = SketchDocument(objects: [.part(inst)], assets: [def.graphicAsset: svgData(20, 10)], parts: [def.key: def])
    let (r, _, _) = render(d, zoom: 1)
    #expect(r.liveLayerCount == 1)
}

@Test @MainActor func rasterCacheEvictsLeastRecentlyUsed() {
    func image(_ side: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    let cache = PartRasterCache(byteBudget: 3 * 100 * 100 * 4)
    let k = (0..<4).map { PartRasterCache.Key(asset: "a\($0)", bucket: 0) }
    for i in 0..<3 { cache.insert(image(100), for: k[i]) }
    #expect(cache.totalBytes == 3 * 40_000)
    _ = cache.image(for: k[0]) // touch: k1 becomes oldest
    cache.insert(image(100), for: k[3])
    #expect(!cache.contains(k[1]))
    #expect(cache.contains(k[0]) && cache.contains(k[2]) && cache.contains(k[3]))
    #expect(cache.totalBytes <= cache.byteBudget)
}

@Test @MainActor func bucketsArePowersOfTwo() {
    #expect(PartRasterCache.bucket(forPixelsPerMM: 12.6) == 4)
    #expect(PartRasterCache.bucket(forPixelsPerMM: 16) == 4)
    #expect(PartRasterCache.bucket(forPixelsPerMM: 16.1) == 5)
    #expect(PartRasterCache.bucket(forPixelsPerMM: 0.63) == 0)
}

@Test @MainActor func rasterCacheReusesBucket() async {
    let (d, _) = doc(definition(20, 10))
    let factory = CALayerObjectFactory()
    let (r, root, _) = render(d, zoom: 1, factory: factory)
    await factory.waitForRasters()
    #expect(factory.rasterJobCount == 1)
    r.update(document: d, viewport: Viewport(center: .zero, zoom: 1.1), viewSize: viewSize, settled: true)
    await factory.waitForRasters()
    #expect(factory.rasterJobCount == 1)
    let part = objectsLayer(root).sublayers!.first as! PartLayer
    #expect(part.body.contents != nil)
    r.update(document: d, viewport: Viewport(center: .zero, zoom: 4), viewSize: viewSize, settled: true)
    await factory.waitForRasters()
    #expect(factory.rasterJobCount == 2)
}
