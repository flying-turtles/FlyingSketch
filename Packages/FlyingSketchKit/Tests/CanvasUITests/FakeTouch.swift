import UIKit
@testable import CanvasUI

/// A `UITouch` at a settable view point, so tests can drive the real `touchesBegan` / `touchesMoved` /
/// `touchesEnded` handlers (no event: coalesced samples fall back to the touch itself).
final class FakeTouch: UITouch {
    var point: CGPoint
    private let kind: UITouch.TouchType

    init(at point: CGPoint, type: UITouch.TouchType = .pencil) {
        self.point = point
        kind = type
        super.init()
    }

    override var type: UITouch.TouchType { kind }
    override var timestamp: TimeInterval { 0 }
    override var force: CGFloat { 1 }
    override var maximumPossibleForce: CGFloat { 2 }
    override func location(in view: UIView?) -> CGPoint { point }
    override func preciseLocation(in view: UIView?) -> CGPoint { point }
}

extension CanvasView {
    /// One touch down at `start`, moved through `path`, lifted at its last point (or `start`).
    func drive(_ touch: FakeTouch, from start: CGPoint, through path: [CGPoint] = []) {
        touch.point = start
        touchesBegan([touch], with: nil)
        for p in path {
            touch.point = p
            touchesMoved([touch], with: nil)
        }
        touchesEnded([touch], with: nil)
    }
}
