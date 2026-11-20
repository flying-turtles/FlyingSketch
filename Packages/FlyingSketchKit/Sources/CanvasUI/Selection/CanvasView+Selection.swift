import UIKit
import Observation
import SketchCore

// CanvasView has its own `bounds`/`hitTest` members, which shadow the SketchCore functions inside the class.
// Doc-aware: parts use their definitions (body + legs), not the 10 mm fallback square.
private func worldBounds(_ o: SceneObject, _ doc: SketchDocument) -> Rect { bounds(of: o, in: doc) }
private func objectHit(_ o: SceneObject, _ p: Vec2, _ tol: Double, _ doc: SketchDocument) -> Bool {
    hitTest(o, point: p, tolerance: tol, in: doc)
}

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
        if let id = textSession?.existing?.id, !doc.objects.contains(where: { $0.id == id }) {
            endTextEditing() // edited text vanished (undo etc.): drop the editor, commit is a no-op
        }
        if wires.documentDidChange(doc) { clearWirePreview() }
        if bends.documentDidChange(doc) { cancelWireBendDrag() }
        if rotator.documentDidChange(doc) { cancelRotate() }
        refreshNetHighlight(after: doc)
        render(settled: true)
    }

    // MARK: Geometry

    var selectedObjects: [SceneObject] {
        guard !selection.ids.isEmpty else { return [] }
        return model.document.objects.filter { selection.ids.contains($0.id) }
    }

    var selectionWorldBounds: Rect? {
        let doc = model.document
        return selectedObjects.map { worldBounds($0, doc) }.reduce(nil) { acc, r in acc.map { $0.union(r) } ?? r }
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
        selectionOverlay.update(viewRect: rotator.isActive ? nil : selectionViewRect) // box hidden while rotating
        updateLegHandles()
        updateWireHandles()
        updateRotateHandle()
    }

    // MARK: Tap and lasso

    /// Objects hit at a world point (tolerance `hitSlop`), bottom to top.
    func hitObjects(atWorld w: Vec2) -> [SceneObject] {
        let tol = Self.hitSlop / (Viewport.pointsPerMillimetre * currentViewport.zoom)
        let box = Rect(origin: w - Vec2(x: tol, y: tol), size: Vec2(x: 2 * tol, y: 2 * tol))
        let doc = model.document
        return renderer.objects(in: box).filter { objectHit($0, w, tol, doc) }
    }

    func topObject(at viewPoint: CGPoint) -> SceneObject? {
        let hits = hitObjects(atWorld: worldPoint(viewPoint))
        // Pins win every tap, whatever the z-order.
        return hits.last { if case .joint = $0 { true } else { false } } ?? hits.last
    }

    /// Finger tap outside the selection: a pin of a selected part (or end of a selected wire) highlights its net,
    /// anything else is a selection tap.
    func handleTap(at viewPoint: CGPoint) {
        if !highlightNet(at: viewPoint) { tap(at: viewPoint) }
    }

    func tap(at viewPoint: CGPoint) {
        let hit = topObject(at: viewPoint)
        selection.ids = hit.map { expandedToGroups([$0.id]) } ?? []
        updateSelectionOverlay()
        if hit != nil { presentEditMenu() }
    }

    func finishLasso() {
        lassoPath.clear()
        selection.ids = expandedToGroups(lasso.end())
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
            moveSet = movingSet()
            moveRigid = selection.ids
        }
        moveDelta = delta
        // Parts and wires re-render from moved geometry (carried parts, attached wire ends); the rest translate.
        let replaced = movedObjects(moveSet, rigid: moveRigid, by: delta).filter(Self.isConnectable)
        let rigid = Set(selectedObjects.filter { !Self.isConnectable($0) }.map(\.id))
        renderer.setMovePreview(ids: rigid, offset: CGPoint(x: delta.x * scale, y: delta.y * scale),
                                replacing: replaced)
        updateSelectionOverlay()
    }

    func endMove() {
        let delta = moveDelta
        let engaged = moveEngaged
        let start = moveStart
        let moving = moveSet
        let rigid = moveRigid
        resetMove()
        guard engaged, delta.length > 0 else {
            // Unengaged = a tap: re-target the selection unless it landed on an already selected object.
            guard let start else { return }
            let v = currentViewport.worldToView(start, viewSize: viewSize)
            let point = CGPoint(x: v.x, y: v.y)
            if highlightNet(at: point) { return } // a connector under the tap wins over selecting
            if let hit = topObject(at: point), selection.ids.contains(hit.id) {
                presentEditMenu()
            } else {
                tap(at: point)
            }
            return
        }
        // Drop: snap the moved parts' males into nearby females of parts left in place, in the same edit.
        let snapped = delta + plugSnap(moving, rigid: rigid, movedBy: delta)
        model.perform(.replace(movedObjects(moving, rigid: rigid, by: snapped)), actionName: "Move")
        updateSelectionOverlay()
    }

    func cancelMove() { resetMove() }

    private func resetMove() {
        moveStart = nil
        moveSet = []
        moveRigid = []
        moveDelta = .zero
        moveEngaged = false
        renderer.setMovePreview(ids: [], offset: .zero)
        updateSelectionOverlay()
    }

    // MARK: Actions

    public func deleteSelection() {
        let objects = selectedObjects
        guard !objects.isEmpty else { return }
        // Wires attached to deleted parts stay, detached (attachment cleared, position kept), in the same edit.
        model.perform(deletionEdits(Set(objects.map(\.id)), in: model.document), actionName: "Delete")
        selection.ids = []
    }

    public func duplicateSelection() {
        let copies = cloned(selectedObjects, by: Self.duplicateOffset, into: model.document)
        guard !copies.isEmpty else { return }
        model.perform(.insert(copies, at: nil), actionName: "Duplicate")
        selection.ids = Set(copies.map(\.id))
    }

    public func copySelection() {
        let objects = selectedObjects
        guard !objects.isEmpty else { return }
        let doc = model.document
        var assets: [String: Data] = [:]
        var definitions: [String: PartDefinition] = [:]
        for o in objects {
            switch o {
            case .image(let i):
                if let data = doc.assets[i.assetName] { assets[i.assetName] = data }
            case .part(let p):
                guard let def = doc.parts[p.definitionKey] else { continue }
                definitions[def.key] = def
                if let data = doc.assets[def.graphicAsset] { assets[def.graphicAsset] = data }
            default:
                break
            }
        }
        Clipboard.write(objects, assets: assets, definitions: definitions)
    }

    public func paste() {
        guard let clip = Clipboard.read(), !clip.objects.isEmpty else { return }
        let prepared = Clipboard.prepare(clip.objects, assets: clip.assets, definitions: clip.definitions,
                                         for: model.document, centeredAt: viewport.center)
        guard !prepared.objects.isEmpty else { return }
        guard (try? model.addAssets(prepared.assets)) != nil else { return } // prepare drops unsafe names
        let defs: [SceneEdit] = prepared.definitions.isEmpty ? [] : [.setDefinitions(prepared.definitions.mapValues { $0 })]
        model.perform(defs + [.insert(prepared.objects, at: nil)], actionName: "Paste")
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
        if selectionCanGroup {
            items.append(UIAction(title: "Group", image: UIImage(systemName: "square.on.square.squareshape.controlhandles")) { [weak self] _ in
                self?.groupSelection()
            })
        }
        if selectionCanUngroup {
            items.append(UIAction(title: "Ungroup", image: UIImage(systemName: "square.on.square.dashed")) { [weak self] _ in
                self?.ungroupSelection()
            })
        }
        if selectionCanLock {
            let locked = selectionIsLocked
            items.append(UIAction(title: locked ? "Unlock" : "Lock in Place",
                                  image: UIImage(systemName: locked ? "lock.open" : "lock")) { [weak self] _ in
                self?.toggleLockSelection()
            })
        }
        if selectionContainsParts {
            items.append(UIAction(title: "Rotate ↻", image: UIImage(systemName: "rotate.right")) { [weak self] _ in
                self?.rotateSelectedParts(clockwise: true)
            })
            items.append(UIAction(title: "Rotate ↺", image: UIImage(systemName: "rotate.left")) { [weak self] _ in
                self?.rotateSelectedParts(clockwise: false)
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
        if menuAnchor == nil, var rect = selectionViewRect {
            let lift = Self.rotateHandleOffset + Self.rotateHitRadius // keep the menu above the rotate knob
            rect.origin.y -= lift
            rect.size.height += lift
            return rect
        }
        return CGRect(origin: menuAnchor ?? configuration.sourcePoint, size: CGSize(width: 1, height: 1))
    }
}
