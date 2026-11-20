import UIKit
import SketchCore

/// Bend and insert handles on selected wires, and dragging them.
extension CanvasView {
    /// Handles of selected wires in document order (bends, then inserts, per wire), following an in-flight bend
    /// drag and selection move. Insert handles on segments shorter than 3 handle diameters are left out.
    func selectedWireHandles() -> [(handle: WireHandle, position: Vec2)] {
        guard !selection.ids.isEmpty else { return [] }
        var doc = model.document
        if moveEngaged { _ = SceneEdit.replace(movedObjects(moveSet, rigid: moveRigid, by: moveDelta)).apply(to: &doc) }
        if let bendPreview { _ = SceneEdit.replace([.wire(bendPreview)]).apply(to: &doc) }
        let minSegment = 6 * legHandleRadius
        var result: [(WireHandle, Vec2)] = []
        for case .wire(let w) in doc.objects where selection.ids.contains(w.id) {
            for (i, b) in w.bends.enumerated() { result.append((.bend(wire: w.id, index: i), b)) }
            let p = w.polyline
            for (s, mid) in w.segmentMidpoints.enumerated() where p[s].distance(to: p[s + 1]) >= minSegment {
                result.append((.insert(wire: w.id, segment: s), mid))
            }
        }
        return result
    }

    /// Handle nearest to `p` within the handle radius; a bend beats an insert handle at equal distance.
    func wireHandle(at p: CGPoint) -> WireHandle? {
        let w = worldPoint(p)
        let r = legHandleRadius
        var best: (handle: WireHandle, d: Double)?
        for (handle, pos) in selectedWireHandles() {
            let d = pos.distance(to: w)
            guard d <= r else { continue }
            guard let current = best else { best = (handle, d); continue }
            let isBend = if case .bend = handle { true } else { false }
            let currentIsBend = if case .bend = current.handle { true } else { false }
            if d < current.d || (d == current.d && isBend && !currentIsBend) { best = (handle, d) }
        }
        return best?.handle
    }

    func updateWireHandles() {
        let scale = Viewport.pointsPerMillimetre * currentViewport.zoom
        let bendPath = CGMutablePath()
        let insertPath = CGMutablePath()
        let r = 0.6 * legHandleRadius * scale // insert handle radius (pt)
        for (handle, pos) in selectedWireHandles() {
            let v = currentViewport.worldToView(pos, viewSize: viewSize)
            switch handle {
            case .bend:
                bendPath.addEllipse(in: CGRect(x: v.x - scale, y: v.y - scale, width: 2 * scale, height: 2 * scale))
            case .insert:
                insertPath.addEllipse(in: CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r))
                let arm = r * 0.55
                insertPath.move(to: CGPoint(x: v.x - arm, y: v.y))
                insertPath.addLine(to: CGPoint(x: v.x + arm, y: v.y))
                insertPath.move(to: CGPoint(x: v.x, y: v.y - arm))
                insertPath.addLine(to: CGPoint(x: v.x, y: v.y + arm))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, path) in [(wireBendHandles, bendPath), (wireInsertHandles, insertPath)] {
            layer.path = path
            layer.isHidden = path.isEmpty
            layer.contentsScale = traitCollection.displayScale
        }
        CATransaction.commit()
    }

    func beginWireBendDrag(_ handle: WireHandle, at world: Vec2) {
        bends.minDistance = Double(Self.legMinTravel) / (Viewport.pointsPerMillimetre * currentViewport.zoom)
        bends.snapsToGrid = snapsToGrid
        bends.begin(handle, grabAt: world)
        moveWireBend(to: world)
    }

    func moveWireBend(to world: Vec2) {
        guard let preview = bends.move(to: world) else { return }
        bendPreview = preview
        renderer.setMovePreview(ids: [], offset: .zero, replacing: [.wire(preview)])
        updateWireHandles()
    }

    func endWireBendDrag(at world: Vec2) {
        guard bends.isActive else { return }
        clearBendPreview()
        bends.end(at: world)
    }

    func cancelWireBendDrag() {
        bends.cancel()
        clearBendPreview()
    }

    private func clearBendPreview() {
        bendPreview = nil
        renderer.setMovePreview(ids: [], offset: .zero)
        updateWireHandles()
    }
}
