import UIKit
import SketchCore

/// Leg end handles and leg dragging for selected legged parts.
extension CanvasView {
    /// Leg-end handle hit radius (mm): at least 1 mm, at least 12 pt on screen.
    var legHandleRadius: Double { max(1, 12 / (Viewport.pointsPerMillimetre * currentViewport.zoom)) }
    /// Releases under this travel (pt) are no-ops.
    static let legMinTravel: CGFloat = 4

    /// Leg ends (part, connector, world position) of selected parts, following an in-flight leg drag.
    func selectedLegEnds() -> [(ref: ConnectorRef, position: Vec2)] {
        guard !selection.ids.isEmpty else { return [] }
        var doc = model.document
        if !legPreview.isEmpty { _ = SceneEdit.replace(legPreview).apply(to: &doc) }
        if moveEngaged { _ = SceneEdit.replace(movedObjects(moveSet, rigid: moveRigid, by: moveDelta)).apply(to: &doc) }
        var result: [(ConnectorRef, Vec2)] = []
        for case .part(let p) in doc.objects where selection.ids.contains(p.id) {
            guard let def = doc.parts[p.definitionKey] else { continue }
            let positions = connectorPositions(p, def)
            for c in def.connectors where c.leg != nil {
                if let pos = positions[c.id] { result.append((ConnectorRef(part: p.id, connector: c.id), pos)) }
            }
        }
        return result
    }

    /// Selected leg end nearest to `p` within the handle radius, if any.
    func legEnd(at p: CGPoint) -> ConnectorRef? {
        let w = worldPoint(p)
        let r = legHandleRadius
        var best: (ref: ConnectorRef, d: Double)?
        for (ref, pos) in selectedLegEnds() {
            let d = pos.distance(to: w)
            guard d <= r else { continue }
            if d < (best?.d ?? .infinity) { best = (ref, d) } // strict <: document order breaks ties
        }
        return best?.ref
    }

    func updateLegHandles() {
        let scale = Viewport.pointsPerMillimetre * currentViewport.zoom
        let path = CGMutablePath()
        for (_, pos) in rotator.isActive ? [] : selectedLegEnds() {
            let v = currentViewport.worldToView(pos, viewSize: viewSize)
            path.addEllipse(in: CGRect(x: v.x - scale, y: v.y - scale, width: 2 * scale, height: 2 * scale))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        legHandles.path = path
        legHandles.isHidden = path.isEmpty
        legHandles.contentsScale = traitCollection.displayScale
        CATransaction.commit()
    }

    func beginLegDrag(_ ref: ConnectorRef, at world: Vec2) {
        legs.minDistance = Double(Self.legMinTravel) / (Viewport.pointsPerMillimetre * currentViewport.zoom)
        legs.begin(part: ref.part, connector: ref.connector, grabAt: world)
        moveLeg(to: world)
    }

    func moveLeg(to world: Vec2) {
        guard legs.isActive else { return }
        legPreview = legs.move(to: world)
        renderer.setMovePreview(ids: [], offset: .zero, replacing: legPreview)
        updateLegHandles()
        updateRotateHandle()
    }

    func endLegDrag(at world: Vec2) {
        guard legs.isActive else { return }
        let isTap = legs.grab.distance(to: world) < legs.minDistance
        legs.move(to: world)
        clearLegPreview()
        legs.end()
        if isTap {
            let v = currentViewport.worldToView(world, viewSize: viewSize)
            highlightNet(at: CGPoint(x: v.x, y: v.y)) // a tap (no drag) on a leg end that is a connector
        }
    }

    func cancelLegDrag() {
        legs.cancel()
        clearLegPreview()
    }

    private func clearLegPreview() {
        legPreview = []
        renderer.setMovePreview(ids: [], offset: .zero)
        updateLegHandles()
        updateRotateHandle()
    }
}
