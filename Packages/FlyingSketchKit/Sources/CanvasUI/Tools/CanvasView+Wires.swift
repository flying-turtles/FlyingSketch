import UIKit
import SketchCore

/// Per-touch state of the wire tool.
struct WireTouch {
    /// Touch-down landed within the hit radius of the open wire's last point.
    var downOnLast = false
    /// This touch started the session.
    var startedSession = false
    /// Polyline currently drawn on the preview layer (world mm).
    var displayed: [Vec2] = []
}

/// Wire tool: drawing with bends, endpoint dragging, live preview.
extension CanvasView {
    var wireRadius: Double { WireController.hitRadius(zoom: currentViewport.zoom) }

    // MARK: Draw

    func beginWire(at world: Vec2) {
        let radius = wireRadius
        if let last = wires.lastPoint, wires.isOpen {
            // Continue from the last point; a touch-down far away still continues (the rubber band jumps).
            wireTouch = WireTouch(downOnLast: last.distance(to: world) <= radius, startedSession: false,
                                  displayed: wireTouch.displayed)
        } else {
            wires.color = toolState.color
            wires.begin(at: world, radius: radius)
            wireTouch = WireTouch(downOnLast: false, startedSession: true)
        }
        moveWire(to: world)
    }

    func moveWire(to world: Vec2) {
        guard wires.isOpen else { return }
        showWirePreview(wires.moveRubberBand(to: world))
    }

    /// Lift: tap on the last point finishes free; over a connector finishes; elsewhere adds a bend, stays open.
    func endWire(at world: Vec2) {
        guard wires.isOpen, let last = wires.lastPoint else { return }
        let radius = wireRadius
        let nearLast = last.distance(to: world) <= radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if wireTouch.downOnLast && nearLast {
            if wires.openPoints.count >= 2 { wires.finishFree() } else { wires.cancel() }
            clearWirePreview()
        } else if wireTouch.startedSession && wires.openPoints.count == 1 && nearLast {
            showWirePreview([])  // a tap that only placed the start point: stay open
        } else if wires.connector(near: world, radius: radius) != nil {
            wires.finish(at: world, radius: radius)
            clearWirePreview()
        } else {
            wires.addBend(at: world)
            showWirePreview(wires.openPoints)
        }
    }

    /// Wire touch cancelled (second finger, window gone): the open wire stays, without the rubber band.
    func cancelWireTouch() {
        if wires.isOpen { showWirePreview(wires.openPoints) }
    }

    /// Tool change or two-finger tap: finishes the open wire as a free end (no edit under 2 points).
    func endWireSession() {
        if let kind = interaction {
            switch kind {
            case .wire, .wireEnd: cancelInteraction()
            default: break
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wires.finishFree()
        wires.cancel()
        clearWirePreview()
        CATransaction.commit()
    }

    // MARK: End drag

    func beginWireEndDrag(at world: Vec2) {
        wires.dragSlop = Self.hitSlop / 2 / (Viewport.pointsPerMillimetre * currentViewport.zoom)
        wires.beginEndDrag(at: world, radius: wireRadius)
    }

    func moveWireEnd(to world: Vec2) {
        guard let preview = wires.moveEndDrag(to: world, radius: wireRadius) else { return }
        renderer.setMovePreview(ids: [], offset: .zero, replacing: [.wire(preview)])
    }

    func endWireEndDrag(at world: Vec2) {
        renderer.setMovePreview(ids: [], offset: .zero)
        wires.finishEndDrag(at: world, radius: wireRadius)
    }

    func cancelWireEndDrag() {
        wires.cancelEndDrag()
        renderer.setMovePreview(ids: [], offset: .zero)
    }

    // MARK: Preview layer

    func showWirePreview(_ polyline: [Vec2]) {
        wireTouch.displayed = polyline
        refreshWirePreview()
    }

    func clearWirePreview() {
        wireTouch.displayed = []
        wirePreview?.removeFromSuperlayer()
        wirePreview = nil
    }

    /// Re-draws the preview for the current viewport (also during pan/pinch).
    func refreshWirePreview() {
        guard wires != nil, let wire = wires.previewWire(wireTouch.displayed) else {
            wirePreview?.removeFromSuperlayer()
            wirePreview = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let preview = wirePreview {
            factory.update(preview, for: .wire(wire), viewport: currentViewport, viewSize: viewSize)
        } else {
            let preview = factory.makeLayer(for: .wire(wire), viewport: currentViewport, viewSize: viewSize)
            layer.addSublayer(preview)
            wirePreview = preview
        }
        CATransaction.commit()
    }
}
