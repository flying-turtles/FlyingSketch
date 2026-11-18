import UIKit

/// UIKit touch and gesture plumbing; forwards to the testable `touchDown`/`touchMoved`/`touchEnded` API.
extension StudioCanvasView {
    // MARK: UIKit touches

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let directCount = event?.allTouches?.filter { $0.type == .direct }.count ?? 0
        let touch = touches.first { $0.type == .pencil } ?? touches.first
        guard let touch else { return }
        if touchDown(at: touch.location(in: self), isPencil: touch.type == .pencil, directTouchCount: directCount) {
            activeTouch = touch
        }
    }

    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        for t in event?.coalescedTouches(for: touch) ?? [touch] { touchMoved(to: t.location(in: self)) }
    }

    override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        touchMoved(to: touch.location(in: self))
        touchEnded()
    }

    override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelTool()
    }

    override public func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { cancelTool() }
    }

    // MARK: Gestures

    @objc func handleGesture(_ g: UIGestureRecognizer) {
        switch g.state {
        case .began:
            gestureBegan()
        case .changed:
            if let pg = g as? UIPanGestureRecognizer {
                pan(by: pg.translation(in: self))
                pg.setTranslation(.zero, in: self)
            } else if let pg = g as? UIPinchGestureRecognizer {
                zoom(by: pg.scale, around: pg.location(in: self))
                pg.scale = 1
            }
        default:
            break
        }
    }

    public func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
        true
    }
}
