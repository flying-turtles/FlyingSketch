import UIKit
import SketchCore

/// Rotate handle above the selection box, and dragging it.
extension CanvasView {
    /// Knob centre above the box top edge, knob radius and hit radius (pt).
    static let rotateHandleOffset: CGFloat = 28
    static let rotateKnobRadius: CGFloat = 7
    static let rotateHitRadius: CGFloat = 16

    /// Knob centre in view space; nil with no selection, while a move, leg, bend, rotate, mechanism or pin drag is
    /// in flight, or when the rotation would break a pin (`rotationIsPinned`).
    var rotateHandleCenter: CGPoint? {
        guard !selectionChromeHidden, !moveEngaged, legPreview.isEmpty, bendPreview == nil,
              let r = selectionViewRect, !rotationIsPinned else { return nil }
        switch interaction {
        case .leg, .wireBend: return nil
        default: return CGPoint(x: r.midX, y: r.minY - Self.rotateHandleOffset)
        }
    }

    func rotateHandleHit(at p: CGPoint) -> Bool {
        guard let c = rotateHandleCenter else { return false }
        return hypot(p.x - c.x, p.y - c.y) <= Self.rotateHitRadius
    }

    func updateRotateHandle() {
        let path = CGMutablePath()
        if let c = rotateHandleCenter, let r = selectionViewRect {
            let k = Self.rotateKnobRadius
            path.addEllipse(in: CGRect(x: c.x - k, y: c.y - k, width: 2 * k, height: 2 * k))
            path.move(to: CGPoint(x: c.x, y: c.y + k))
            path.addLine(to: CGPoint(x: c.x, y: r.minY))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotateHandle.path = path
        rotateHandle.isHidden = path.isEmpty
        rotateHandle.contentsScale = traitCollection.displayScale
        CATransaction.commit()
    }

    /// Starts rotating the selection about the centre of its bounds, grabbed at world `world`.
    func beginRotate(at world: Vec2) {
        guard let b = selectionWorldBounds else { return }
        rotator.minDistance = Double(Self.legMinTravel) / (Viewport.pointsPerMillimetre * currentViewport.zoom)
        rotator.snapsAngle = snapsToGrid
        rotator.begin(ids: selection.ids, pivot: Vec2(x: (b.minX + b.maxX) / 2, y: (b.minY + b.maxY) / 2), grabAt: world)
        moveRotate(to: world)
    }

    func moveRotate(to world: Vec2) {
        guard rotator.isActive else { return }
        rotatePreview = rotator.move(to: world)
        renderer.setMovePreview(ids: [], offset: .zero, replacing: rotatePreview)
        updateSelectionOverlay()
    }

    func endRotate(at world: Vec2) {
        guard rotator.isActive else { return }
        clearRotatePreview() // same transaction as the commit (see touchesEnded)
        rotator.end(at: world)
        updateSelectionOverlay()
    }

    func cancelRotate() {
        rotator.cancel()
        clearRotatePreview()
        updateSelectionOverlay()
    }

    private func clearRotatePreview() {
        rotatePreview = []
        renderer.setMovePreview(ids: [], offset: .zero)
    }
}
