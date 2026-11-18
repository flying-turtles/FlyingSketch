import UIKit
import SketchCore

/// Culled Core Animation renderer. Settled updates rebuild view-space geometry for objects near the viewport;
/// unsettled updates only apply an affine transform relative to the last settled viewport.
final class SceneRenderer {
    private struct Entry {
        var layer: CALayer
        var object: SceneObject
        var viewport: Viewport
        var viewSize: Vec2
    }

    private let content = CALayer()
    private let grid = GridLayer()
    private let objects = CALayer()
    let netLayers = NetOverlayLayers()
    private let factory: any ObjectLayerFactory

    private var index = SpatialIndex(cellSize: 50)
    private var lastObjects: [SceneObject] = []
    private var lastParts: [String: PartDefinition] = [:]
    private var objectsByID: [ObjectID: SceneObject] = [:]
    private var zIndex: [ObjectID: Int] = [:]
    private var entries: [ObjectID: Entry] = [:]
    private var settledViewport: Viewport?
    private var settledViewSize: Vec2 = .zero

    var showsGrid = true
    /// Highlighted net geometry (world mm); re-pathed on every settle. Hidden while part/wire previews run.
    var netOverlay: NetOverlay? { didSet { repaintNetOverlay() } }
    var screenScale: CGFloat = 2 { didSet { repaintNetOverlay() } }

    private func repaintNetOverlay() {
        guard let vp = settledViewport else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        netLayers.update(netOverlay, viewport: vp, viewSize: settledViewSize, scale: screenScale)
        CATransaction.commit()
    }
    /// Ids whose object changed in the latest `syncIndex`.
    private var dirty: Set<ObjectID> = []
    /// Number of settled updates performed (debug/test).
    private(set) var settleCount = 0

    /// Object layers only (no grid or container layers).
    var liveLayerCount: Int { entries.count }

    // MARK: Visual-only feedback (erase hiding, move preview)

    /// Layers hidden immediately while an eraser gesture runs. Document is untouched.
    var hiddenIDs: Set<ObjectID> = [] { didSet { if hiddenIDs != oldValue { applyFeedback() } } }
    /// Objects previewed translated by `moveOffset` view points. Document is untouched.
    private(set) var movingIDs: Set<ObjectID> = []
    private(set) var moveOffset: CGPoint = .zero
    /// Objects previewed with substitute geometry (moved parts, re-pathed wires), keyed by id. Document is untouched.
    private(set) var previewObjects: [ObjectID: SceneObject] = [:]
    private var feedbackBase: [ObjectID: (layer: CALayer, transform: CATransform3D)] = [:]
    /// Layers currently showing a `previewObjects` substitute; restored to their entry's object on clear.
    private var substituted: Set<ObjectID> = []

    /// `ids` are translated rigidly by `offset`; `replacing` objects are re-rendered from the given geometry
    /// (an id in both is only re-rendered).
    func setMovePreview(ids: Set<ObjectID>, offset: CGPoint, replacing: [SceneObject] = []) {
        movingIDs = ids
        moveOffset = offset
        previewObjects = Dictionary(replacing.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        applyFeedback()
    }

    private func clearFeedback() {
        for (_, b) in feedbackBase {
            b.layer.isHidden = false
            b.layer.transform = b.transform
        }
        feedbackBase.removeAll(keepingCapacity: true)
        for id in substituted {
            guard let e = entries[id] else { continue }
            factory.update(e.layer, for: e.object, viewport: e.viewport, viewSize: e.viewSize)
        }
        substituted.removeAll(keepingCapacity: true)
    }

    private func applyFeedback() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        clearFeedback()
        netLayers.suppressed = !previewObjects.isEmpty
        for (id, object) in previewObjects {
            guard let e = entries[id] else { continue }
            factory.update(e.layer, for: object, viewport: e.viewport, viewSize: e.viewSize)
            substituted.insert(id)
        }
        for id in hiddenIDs.union(movingIDs) {
            guard let e = entries[id] else { continue }
            feedbackBase[id] = (e.layer, e.layer.transform)
            if hiddenIDs.contains(id) { e.layer.isHidden = true }
            if movingIDs.contains(id), previewObjects[id] == nil {
                e.layer.transform = CATransform3DConcat(e.layer.transform,
                                                        CATransform3DMakeTranslation(moveOffset.x, moveOffset.y, 0))
            }
        }
    }

    // MARK: Queries (as of the last settle)

    /// Objects whose bounds intersect `rect`, bottom to top.
    func objects(in rect: Rect) -> [SceneObject] {
        index.query(rect).compactMap { objectsByID[$0] }.sorted { (zIndex[$0.id] ?? 0) < (zIndex[$1.id] ?? 0) }
    }

    init(rootLayer: CALayer, factory: any ObjectLayerFactory = CALayerObjectFactory()) {
        self.factory = factory
        content.anchorPoint = .zero
        content.position = .zero
        content.addSublayer(grid.layer)
        content.addSublayer(netLayers.glow)
        content.addSublayer(objects)
        content.addSublayer(netLayers.rings)
        rootLayer.addSublayer(content)
    }

    func update(document: SketchDocument, viewport: Viewport, viewSize: Vec2, settled: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if settled {
            settle(document, viewport, viewSize)
        } else {
            applyGestureTransform(viewport, viewSize)
        }
    }

    // MARK: Gesture

    private func applyGestureTransform(_ vp: Viewport, _ size: Vec2) {
        guard let base = settledViewport else { return }
        let ppm = Viewport.pointsPerMillimetre
        let s = vp.zoom / base.zoom
        let shift = (base.center - vp.center) * (vp.zoom * ppm)
        let t = CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                  tx: size.x / 2 * (1 - s) + shift.x,
                                  ty: size.y / 2 * (1 - s) + shift.y)
        content.sublayerTransform = CATransform3DMakeAffineTransform(t)
    }

    // MARK: Settle

    private func settle(_ document: SketchDocument, _ vp: Viewport, _ size: Vec2) {
        settleCount += 1
        clearFeedback()
        defer { applyFeedback() }
        syncIndex(document)
        factory.prepare(document: document)
        content.sublayerTransform = CATransform3DIdentity
        content.bounds = CGRect(x: 0, y: 0, width: size.x, height: size.y)
        settledViewport = vp
        settledViewSize = size
        netLayers.update(netOverlay, viewport: vp, viewSize: size, scale: screenScale)

        let visible = vp.visibleWorldRect(viewSize: size)
        let culling = Rect(origin: visible.origin - visible.size * 0.25, size: visible.size * 1.5)
        grid.update(viewport: vp, viewSize: size, worldRect: culling, visible: showsGrid)

        let wanted = index.query(culling)
        for id in entries.keys where !wanted.contains(id) {
            entries[id]?.layer.removeFromSuperlayer()
            entries[id] = nil
        }
        for id in wanted {
            guard let object = objectsByID[id] else { continue }
            show(object, vp, size)
        }
    }

    private func show(_ object: SceneObject, _ vp: Viewport, _ size: Vec2) {
        let z = CGFloat(zIndex[object.id] ?? 0)
        if var e = entries[object.id] {
            if e.viewport != vp || e.viewSize != size || dirty.contains(object.id) {
                if sameKind(e.object, object) {
                    factory.update(e.layer, for: object, viewport: vp, viewSize: size)
                } else {
                    e.layer.removeFromSuperlayer()
                    e.layer = factory.makeLayer(for: object, viewport: vp, viewSize: size)
                    objects.addSublayer(e.layer)
                }
                e.object = object
                e.viewport = vp
                e.viewSize = size
            }
            if e.layer.zPosition != z { e.layer.zPosition = z }
            entries[object.id] = e
        } else {
            let layer = factory.makeLayer(for: object, viewport: vp, viewSize: size)
            layer.zPosition = z
            objects.addSublayer(layer)
            entries[object.id] = Entry(layer: layer, object: object, viewport: vp, viewSize: size)
        }
    }

    private func sameKind(_ a: SceneObject, _ b: SceneObject) -> Bool {
        switch (a, b) {
        case (.ink, .ink), (.shape, .shape), (.text, .text), (.image, .image), (.part, .part), (.wire, .wire): true
        default: false
        }
    }

    /// Inserts, moves and removes index entries by diffing against the previous object list.
    private func syncIndex(_ doc: SketchDocument) {
        let list = doc.objects
        dirty.removeAll(keepingCapacity: true)
        // Part bounds depend on definitions: a changed definition set re-indexes everything.
        let force = doc.parts != lastParts
        lastParts = doc.parts
        guard force || list != lastObjects else { return }
        var next: [ObjectID: SceneObject] = [:]
        next.reserveCapacity(list.count)
        var z: [ObjectID: Int] = [:]
        z.reserveCapacity(list.count)
        for (i, o) in list.enumerated() {
            next[o.id] = o
            z[o.id] = i
        }
        for id in objectsByID.keys where next[id] == nil { index.remove(id) }
        for (id, o) in next where force || objectsByID[id] != o {
            index.insert(id, bounds: bounds(of: o, in: doc))
            dirty.insert(id)
        }
        objectsByID = next
        zIndex = z
        lastObjects = list
    }
}
