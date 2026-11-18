import CoreGraphics
import SketchCore

/// Collects one single-touch stroke in view space and maps it to source pixels.
/// Points closer than `minSpacing` view pt to the previous kept point are dropped.
final class StudioInputController {
    static let minSpacing: CGFloat = 1

    /// Mapping used for each point as it arrives (a zoom mid-stroke cancels the stroke, so it stays fixed).
    var viewToSource: CGAffineTransform = .identity
    private(set) var viewPoints: [CGPoint] = []
    private(set) var sourcePoints: [Vec2] = []
    private(set) var isActive = false

    func begin(_ viewPoint: CGPoint) {
        viewPoints = []
        sourcePoints = []
        isActive = true
        append(viewPoint)
    }

    func move(_ viewPoint: CGPoint) {
        guard isActive, let last = viewPoints.last else { return }
        guard hypot(viewPoint.x - last.x, viewPoint.y - last.y) >= Self.minSpacing else { return }
        append(viewPoint)
    }

    /// Source points of the finished stroke; empty when nothing is active.
    func end() -> [Vec2] {
        defer { reset() }
        return isActive ? sourcePoints : []
    }

    func cancel() { reset() }

    private func append(_ p: CGPoint) {
        viewPoints.append(p)
        let s = p.applying(viewToSource)
        sourcePoints.append(Vec2(x: s.x, y: s.y))
    }

    private func reset() {
        viewPoints = []
        sourcePoints = []
        isActive = false
    }
}
