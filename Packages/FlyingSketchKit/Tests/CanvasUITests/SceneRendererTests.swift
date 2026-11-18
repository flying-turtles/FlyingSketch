import QuartzCore
import Testing
import SketchCore
@testable import CanvasUI

private let viewSize = Vec2(x: 1024, y: 1366)

private func line(at origin: Vec2, length: Double = 10) -> SceneObject {
    .ink(InkStroke(points: [
        InkPoint(position: origin, pressure: 0.5, time: 0),
        InkPoint(position: origin + Vec2(x: length, y: 0), pressure: 0.5, time: 0.1),
    ], tool: .pen, baseWidth: 1))
}

private func objectLayers(_ root: CALayer) -> [CAShapeLayer] {
    // root -> content -> [grid, objects]
    root.sublayers![0].sublayers![1].sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
}

@Test @MainActor func createsLayersOnlyForVisibleObjects() {
    let doc = SketchDocument.fixtureGrid(strokes: 5_000, spacing: 20)
    let r = SceneRenderer(rootLayer: CALayer())
    r.update(document: doc, viewport: Viewport(center: .zero, zoom: 1), viewSize: viewSize, settled: true)
    #expect(r.liveLayerCount > 0 && r.liveLayerCount < 400)
}

@Test @MainActor func removesLayersThatScrollOut() {
    let doc = SketchDocument(objects: [line(at: .zero)])
    let r = SceneRenderer(rootLayer: CALayer())
    r.update(document: doc, viewport: Viewport(center: .zero, zoom: 1), viewSize: viewSize, settled: true)
    #expect(r.liveLayerCount == 1)
    r.update(document: doc, viewport: Viewport(center: Vec2(x: 5_000, y: 5_000), zoom: 1), viewSize: viewSize, settled: true)
    #expect(r.liveLayerCount == 0)
}

@Test @MainActor func layerPathIsInViewCoordinates() {
    let doc = SketchDocument(objects: [line(at: .zero)])
    let root = CALayer()
    let r = SceneRenderer(rootLayer: root)
    r.update(document: doc, viewport: Viewport(center: .zero, zoom: 2), viewSize: viewSize, settled: true)
    let layer = objectLayers(root).first!
    let expected = (10 + 1) * 2 * Viewport.pointsPerMillimetre
    #expect(abs(layer.path!.boundingBox.width - expected) < expected * 0.05)
    // World origin maps to the view centre (minus round cap).
    #expect(layer.frame.minX < viewSize.x / 2 && layer.frame.minX > viewSize.x / 2 - 8)
}

@Test @MainActor func movedObjectIsReindexed() {
    let a = line(at: .zero)
    let r = SceneRenderer(rootLayer: CALayer())
    let home = Viewport(center: .zero, zoom: 1)
    r.update(document: SketchDocument(objects: [a]), viewport: home, viewSize: viewSize, settled: true)
    #expect(r.liveLayerCount == 1)
    let moved = a.translated(by: Vec2(x: 10_000, y: 0))
    r.update(document: SketchDocument(objects: [moved]), viewport: home, viewSize: viewSize, settled: true)
    #expect(r.liveLayerCount == 0)
    r.update(document: SketchDocument(objects: [moved]), viewport: Viewport(center: Vec2(x: 10_000, y: 0), zoom: 1), viewSize: viewSize, settled: true)
    #expect(r.liveLayerCount == 1)
}

@Test @MainActor func unchangedObjectKeepsLayer() {
    let doc = SketchDocument(objects: [line(at: .zero)])
    let root = CALayer()
    let r = SceneRenderer(rootLayer: root)
    r.update(document: doc, viewport: Viewport(center: .zero, zoom: 1), viewSize: viewSize, settled: true)
    let first = objectLayers(root).first
    r.update(document: doc, viewport: Viewport(center: Vec2(x: 3, y: 0), zoom: 1), viewSize: viewSize, settled: true)
    #expect(objectLayers(root).first === first)
}

@Test @MainActor func highlighterUsesMultiplyAt35Percent() {
    let s = InkStroke(points: [InkPoint(position: .zero, pressure: 0.5, time: 0), InkPoint(position: Vec2(x: 5, y: 0), pressure: 0.5, time: 0.1)], tool: .highlighter)
    let root = CALayer()
    let r = SceneRenderer(rootLayer: root)
    r.update(document: SketchDocument(objects: [.ink(s)]), viewport: Viewport(center: .zero, zoom: 1), viewSize: viewSize, settled: true)
    let l = objectLayers(root).first!
    #expect(l.opacity == 0.35)
    #expect(l.compositingFilter as? String == "multiplyBlendMode")
}

@Test @MainActor func gridHiddenBelowQuarterZoom() {
    let root = CALayer()
    let r = SceneRenderer(rootLayer: root)
    let grid = root.sublayers![0].sublayers![0]
    r.update(document: .empty, viewport: Viewport(center: .zero, zoom: 1), viewSize: viewSize, settled: true)
    #expect(!grid.isHidden)
    r.update(document: .empty, viewport: Viewport(center: .zero, zoom: 0.2), viewSize: viewSize, settled: true)
    #expect(grid.isHidden)
}

@Test @MainActor func gestureUpdateAppliesTransformThenSettleResets() {
    let root = CALayer()
    let r = SceneRenderer(rootLayer: root)
    let doc = SketchDocument(objects: [line(at: .zero)])
    r.update(document: doc, viewport: Viewport(center: .zero, zoom: 1), viewSize: viewSize, settled: true)
    r.update(document: doc, viewport: Viewport(center: .zero, zoom: 2), viewSize: viewSize, settled: false)
    let content = root.sublayers![0]
    #expect(content.sublayerTransform.m11 == 2)
    r.update(document: doc, viewport: Viewport(center: .zero, zoom: 2), viewSize: viewSize, settled: true)
    #expect(CATransform3DIsIdentity(content.sublayerTransform))
}
