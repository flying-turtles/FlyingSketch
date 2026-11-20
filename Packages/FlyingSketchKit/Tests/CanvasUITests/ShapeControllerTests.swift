import UIKit
import Testing
import SketchCore
@testable import CanvasUI

@MainActor private func setup() -> (DocumentModel, ShapeController) {
    let m = DocumentModel(document: .empty)
    return (m, ShapeController(model: m))
}

@MainActor private func onlyShape(_ m: DocumentModel) -> ShapeObject? {
    guard m.document.objects.count == 1, case .shape(let s) = m.document.objects[0] else { return nil }
    return s
}

@Test @MainActor func rectangleIsSingleInsert() {
    let (m, c) = setup()
    c.begin(at: Vec2(x: 0, y: 0), kind: .rectangle)
    for i in 1...10 { c.move(to: Vec2(x: Double(i), y: Double(i) * 2), constrain: false) }
    c.end()
    #expect(onlyShape(m)?.end == Vec2(x: 10, y: 20))
    #expect(onlyShape(m)?.fillColor == nil)
    m.undoManager.undo()
    #expect(m.document.objects.isEmpty)
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func constrainedLineSnapsTo15Degrees() {
    let (m, c) = setup()
    let a = 22.0 * .pi / 180
    c.begin(at: .zero, kind: .line)
    c.move(to: Vec2(x: cos(a), y: sin(a)) * 10, constrain: true)
    c.end()
    let s = onlyShape(m)!
    #expect(abs(atan2(s.end.y, s.end.x) - 15.0 * .pi / 180) < 1e-9)
    #expect(abs(s.end.length - 10) < 1e-9)
}

@Test @MainActor func constrainedRectIsSquareAndEllipseIsCircle() {
    for kind in [ShapeKind.rectangle, .ellipse] {
        let (m, c) = setup()
        c.begin(at: Vec2(x: 5, y: 5), kind: kind)
        c.move(to: Vec2(x: -5, y: 8), constrain: true)
        c.end()
        #expect(onlyShape(m)?.end == Vec2(x: -5, y: 15))
    }
}

@Test @MainActor func gridSnapAppliesToStartAndEnd() {
    let (m, c) = setup()
    c.snapsToGrid = true
    c.begin(at: Vec2(x: 3, y: 4), kind: .line)
    c.move(to: Vec2(x: 26, y: 14), constrain: false)
    c.end()
    #expect(onlyShape(m)?.start == Vec2(x: 0, y: 0))
    #expect(onlyShape(m)?.end == Vec2(x: 30, y: 10))
}

@Test @MainActor func tinyDragInsertsNothing() {
    let (m, c) = setup()
    c.minimumLength = 1
    c.begin(at: .zero, kind: .arrow)
    c.move(to: Vec2(x: 0.5, y: 0), constrain: false)
    c.end()
    #expect(m.document.objects.isEmpty)
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func cancelInsertsNothingAndStyleIsApplied() {
    let (m, c) = setup()
    c.strokeColor = RGBAColor(r: 1, g: 0, b: 0, a: 1)
    c.lineWidth = 2
    c.begin(at: .zero, kind: .line)
    c.move(to: Vec2(x: 10, y: 0), constrain: false)
    #expect(c.current?.lineWidth == 2)
    c.cancel()
    c.end()
    #expect(m.document.objects.isEmpty)
}

// MARK: Text

@Test @MainActor func textCommitRules() {
    let m = DocumentModel(document: .empty)
    let t = TextController(model: m)
    #expect(!t.commit("  \n ", existing: nil, position: .zero, fontSize: 5, color: .black))
    #expect(!m.undoManager.canUndo)
    #expect(t.commit("Hi", existing: nil, position: Vec2(x: 3, y: 4), fontSize: 5, color: .black))
    guard case .text(let obj) = m.document.objects[0] else { Issue.record("text"); return }
    #expect(obj.text == "Hi" && obj.position == Vec2(x: 3, y: 4))
    #expect(m.undoManager.undoActionName == "Add Text")

    // unchanged: no edit
    #expect(!t.commit("Hi", existing: obj, position: obj.position, fontSize: 5, color: .black))
    // changed: replace in place
    #expect(t.commit("Yo", existing: obj, position: obj.position, fontSize: 5, color: .black))
    #expect(m.document.objects.count == 1)
    guard case .text(let edited) = m.document.objects[0] else { return }
    #expect(edited.text == "Yo" && edited.id == obj.id)
    // emptied: remove
    #expect(t.commit("", existing: edited, position: obj.position, fontSize: 5, color: .black))
    #expect(m.document.objects.isEmpty)
    #expect(m.undoManager.undoActionName == "Delete Text")
}

// MARK: Images

private func pngData(width: Int, height: Int) -> Data {
    let r = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                    format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
    return r.pngData { ctx in
        UIColor.red.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

@Test @MainActor func imagePlacementStoresAssetAndKeepsAspect() {
    let m = DocumentModel(document: .empty)
    #expect(ImagePlacement.insert(pngData(width: 200, height: 100), into: m, at: Vec2(x: 10, y: 20)))
    guard case .image(let i) = m.document.objects[0] else { Issue.record("image"); return }
    #expect(i.frame.size == Vec2(x: 100, y: 50))
    #expect(i.frame.origin == Vec2(x: -40, y: -5))
    #expect(i.assetName.hasSuffix(".png"))
    #expect(m.document.assets[i.assetName] != nil)
    #expect(m.undoManager.undoActionName == "Add Image")
    m.undoManager.undo()
    #expect(m.document.objects.isEmpty)
}

@Test @MainActor func invalidImageDataDoesNothing() {
    let m = DocumentModel(document: .empty)
    #expect(!ImagePlacement.insert(Data([1, 2, 3]), into: m, at: .zero))
    #expect(m.document.objects.isEmpty && m.document.assets.isEmpty && !m.undoManager.canUndo)
}

@Test @MainActor func canvasInsertImageSelectsIt() {
    let m = DocumentModel(document: .empty)
    let v = CanvasView(model: m)
    v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    v.layoutIfNeeded()
    #expect(v.insertImage(pngData(width: 50, height: 50)))
    #expect(v.selection.ids == [m.document.objects[0].id])
}

@Test @MainActor func rightOrientedImageStoredUpright() throws {
    let raw = UIImage(data: pngData(width: 200, height: 100))!
    let rotated = UIImage(cgImage: raw.cgImage!, scale: 1, orientation: .right) // displays 100 x 200
    let m = DocumentModel(document: .empty)
    let jpeg = try #require(rotated.jpegData(compressionQuality: 1))
    #expect(ImagePlacement.insert(jpeg, into: m, at: .zero))
    guard case .image(let i) = m.document.objects[0] else { Issue.record("image"); return }
    let storedData = try #require(m.document.assets[i.assetName])
    let stored = try #require(UIImage(data: storedData))
    #expect(abs(i.frame.size.y / i.frame.size.x - 2) < 1e-6)
    #expect(abs(stored.size.height * stored.scale / (stored.size.width * stored.scale) - 2) < 0.01)
}

@Test @MainActor func largeImageCappedTo4096() throws {
    let m = DocumentModel(document: .empty)
    #expect(ImagePlacement.insert(pngData(width: 6000, height: 1500), into: m, at: .zero))
    guard case .image(let i) = m.document.objects[0] else { Issue.record("image"); return }
    let storedData = try #require(m.document.assets[i.assetName])
    let stored = try #require(UIImage(data: storedData))
    #expect(stored.size.width * stored.scale == 4096 && stored.size.height * stored.scale == 1024)
}

@Test @MainActor func textBackingStoreScaleIsCapped() {
    #expect(CALayerObjectFactory.cappedContentsScale(width: 100, height: 50, screenScale: 2) == 2)
    let s = CALayerObjectFactory.cappedContentsScale(width: 7200, height: 1200, screenScale: 2)
    #expect(7200 * s <= 4096 && 1200 * s <= 4096 && s < 2)
}

@Test @MainActor func rotatedRectangleLayerPathIsRotated() throws {
    let s = ShapeObject(kind: .rectangle, start: .zero, end: Vec2(x: 20, y: 4), lineWidth: 0, rotation: .pi / 2)
    let root = CALayer()
    let r = SceneRenderer(rootLayer: root)
    let vp = Viewport(center: .zero, zoom: 1)
    let size = Vec2(x: 1024, y: 1366)
    r.update(document: SketchDocument(objects: [.shape(s)]), viewport: vp, viewSize: size, settled: true)
    let layer = try #require(root.sublayers?[0].sublayers?[1].sublayers?.compactMap { $0 as? CAShapeLayer }.first)
    let box = try #require(layer.path?.boundingBoxOfPath)
    // Layer path is relative to the layer frame: back to view coordinates, then world mm.
    let a = vp.viewToWorld(Vec2(x: layer.frame.minX + box.minX, y: layer.frame.minY + box.minY), viewSize: size)
    let b = vp.viewToWorld(Vec2(x: layer.frame.minX + box.maxX, y: layer.frame.minY + box.maxY), viewSize: size)
    #expect(abs(a.x - 8) < 0.01 && abs(a.y + 8) < 0.01)
    #expect(abs(b.x - 12) < 0.01 && abs(b.y - 12) < 0.01)
}

@Test @MainActor func rotatedRectangleLayerPathTurnsClockwise() throws {
    let s = ShapeObject(kind: .rectangle, start: .zero, end: Vec2(x: 20, y: 4), lineWidth: 0, rotation: .pi / 6)
    let root = CALayer()
    let r = SceneRenderer(rootLayer: root)
    let vp = Viewport(center: .zero, zoom: 1)
    let size = Vec2(x: 1024, y: 1366)
    r.update(document: SketchDocument(objects: [.shape(s)]), viewport: vp, viewSize: size, settled: true)
    let layer = try #require(root.sublayers?[0].sublayers?[1].sublayers?.compactMap { $0 as? CAShapeLayer }.first)
    let path = try #require(layer.path)
    func contains(_ w: Vec2) -> Bool {
        let p = vp.worldToView(w, viewSize: size)
        return path.contains(CGPoint(x: p.x - layer.frame.minX, y: p.y - layer.frame.minY))
    }
    let pivot = Vec2(x: 10, y: 2)
    #expect(contains(pivot + Vec2(x: 8, y: 0).rotated(by: .pi / 6)))
    #expect(!contains(pivot + Vec2(x: 8, y: 0).rotated(by: -.pi / 6)))
}
