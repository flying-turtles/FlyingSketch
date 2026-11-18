import UIKit
import Observation
import SketchCore

// CanvasView has its own `bounds`/`hitTest` members, which shadow the SketchCore functions inside the class.
private func worldBounds(_ o: SceneObject) -> Rect { bounds(of: o) }
private func objectHit(_ o: SceneObject, _ p: Vec2, _ tol: Double) -> Bool { hitTest(o, point: p, tolerance: tol) }

/// Selection, move and clipboard actions plus the edit menu.
extension CanvasView {
    /// Duplicate offset in world mm (both axes).
    static let duplicateOffset = Vec2(x: 5, y: 5)

    // MARK: Setup

    func setUpSelectionUI() {
        editMenu = UIEditMenuInteraction(delegate: self)
        addInteraction(editMenu)
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        longPress.delegate = self
        longPress.addTarget(self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(longPress)
        observeSelection()
    }

    private func observeSelection() {
        withObservationTracking {
            _ = selection.ids
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateSelectionOverlay()
                self?.observeSelection()
            }
        }
    }

    func documentChanged(_ doc: SketchDocument) {
        if !selection.ids.isEmpty {
            let existing = Set(doc.objects.map(\.id))
            if !selection.ids.isSubset(of: existing) { selection.ids.formIntersection(existing) }
        }
        render(settled: true)
    }

    // MARK: Geometry

    var selectedObjects: [SceneObject] {
        guard !selection.ids.isEmpty else { return [] }
        return model.document.objects.filter { selection.ids.contains($0.id) }
    }

    var selectionWorldBounds: Rect? {
        selectedObjects.map { worldBounds($0) }.reduce(nil) { acc, r in acc.map { $0.union(r) } ?? r }
    }

    /// Selection bounds in view space (follows an in-flight move preview).
    var selectionViewRect: CGRect? {
        guard let b = selectionWorldBounds else { return nil }
        let vp = currentViewport
        let a = vp.worldToView(Vec2(x: b.minX, y: b.minY) + moveDelta, viewSize: viewSize)
        let c = vp.worldToView(Vec2(x: b.maxX, y: b.maxY) + moveDelta, viewSize: viewSize)
        return CGRect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y)
    }

    func updateSelectionOverlay() {
        selectionOverlay.update(viewRect: selectionViewRect)
    }

    // MARK: Tap and lasso

    func topObject(at viewPoint: CGPoint) -> SceneObject? {
        let w = worldPoint(viewPoint)
        let tol = Self.hitSlop / (Viewport.pointsPerMillimetre * currentViewport.zoom)
        let box = Rect(origin: w - Vec2(x: tol, y: tol), size: Vec2(x: 2 * tol, y: 2 * tol))
        return renderer.objects(in: box).last { objectHit($0, w, tol) }
    }

    func tap(at viewPoint: CGPoint) {
        let hit = topObject(at: viewPoint)
        selection.ids = hit.map { [$0.id] } ?? []
        updateSelectionOverlay()
        if hit != nil { presentEditMenu() }
    }

    func finishLasso() {
        lassoPath.clear()
        selection.ids = lasso.end()
        updateSelectionOverlay()
        if !selection.ids.isEmpty { presentEditMenu() }
    }

    // MARK: Move

    func beginMove(at world: Vec2) {
        guard !selection.ids.isEmpty else { return }
        moveStart = world
        moveDelta = .zero
        moveEngaged = false
    }

    func updateMove(to world: Vec2) {
        guard let start = moveStart else { return }
        let delta = world - start
        let scale = Viewport.pointsPerMillimetre * currentViewport.zoom
        // Ignore finger-tap jitter until the drag is deliberate.
        if !moveEngaged {
            guard delta.length * scale > Self.hitSlop / 2 else { return }
            moveEngaged = true
        }
        moveDelta = delta
        renderer.setMovePreview(ids: selection.ids, offset: CGPoint(x: delta.x * scale, y: delta.y * scale))
        updateSelectionOverlay()
    }

    func endMove() {
        let delta = moveDelta
        let engaged = moveEngaged
        let start = moveStart
        resetMove()
        guard engaged, delta.length > 0 else {
            // Unengaged = a tap: re-target the selection unless it landed on an already selected object.
            guard let start else { return }
            let v = currentViewport.worldToView(start, viewSize: viewSize)
            let point = CGPoint(x: v.x, y: v.y)
            if let hit = topObject(at: point), selection.ids.contains(hit.id) {
                presentEditMenu()
            } else {
                tap(at: point)
            }
            return
        }
        model.perform(.replace(selectedObjects.map { $0.translated(by: delta) }), actionName: "Move")
        updateSelectionOverlay()
    }

    func cancelMove() { resetMove() }

    private func resetMove() {
        moveStart = nil
        moveDelta = .zero
        moveEngaged = false
        renderer.setMovePreview(ids: [], offset: .zero)
        updateSelectionOverlay()
    }

    // MARK: Actions

    public func deleteSelection() {
        let objects = selectedObjects
        guard !objects.isEmpty else { return }
        model.perform(.remove(Set(objects.map(\.id))), actionName: "Delete")
        selection.ids = []
    }

    public func duplicateSelection() {
        let copies = selectedObjects.map { $0.translated(by: Self.duplicateOffset).withID(.new()) }
        guard !copies.isEmpty else { return }
        model.perform(.insert(copies, at: nil), actionName: "Duplicate")
        selection.ids = Set(copies.map(\.id))
    }

    public func copySelection() {
        let objects = selectedObjects
        guard !objects.isEmpty else { return }
        var assets: [String: Data] = [:]
        for case .image(let i) in objects {
            if let data = model.document.assets[i.assetName] { assets[i.assetName] = data }
        }
        Clipboard.write(objects, assets: assets)
    }

    public func paste() {
        guard let clip = Clipboard.read(), !clip.objects.isEmpty else { return }
        let prepared = Clipboard.prepare(clip.objects, assets: clip.assets, for: model.document,
                                         centeredAt: viewport.center)
        guard !prepared.objects.isEmpty else { return }
        model.addAssets(prepared.assets)
        model.perform(.insert(prepared.objects, at: nil), actionName: "Paste")
        selection.ids = Set(prepared.objects.map(\.id))
    }

    // MARK: Edit menu

    @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        // Consume the pending finger so its release does not clear the selection.
        activeTouch = nil
        interaction = nil
        presentEditMenu(at: g.location(in: self))
    }

    func presentEditMenu(at point: CGPoint? = nil) {
        guard window != nil else { return }
        menuAnchor = point
        let source = point ?? selectionViewRect.map { CGPoint(x: $0.midX, y: $0.minY) } ?? .zero
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: source))
    }
}

extension CanvasView: UIEditMenuInteractionDelegate {
    public func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                    suggestedActions: [UIMenuElement]) -> UIMenu? {
        var items: [UIMenuElement] = []
        if !selection.ids.isEmpty {
            items.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.deleteSelection()
            })
            items.append(UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                self?.duplicateSelection()
            })
            items.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copySelection()
            })
        }
        if Clipboard.hasContent {
            items.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.paste()
            })
        }
        return items.isEmpty ? nil : UIMenu(children: items)
    }

    public func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        if menuAnchor == nil, let rect = selectionViewRect { return rect }
        return CGRect(origin: menuAnchor ?? configuration.sourcePoint, size: CGSize(width: 1, height: 1))
    }
}
