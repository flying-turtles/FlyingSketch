import Foundation

/// Shared joint mark geometry (mm). Canvas and exporters draw from this; nothing else holds these numbers.
public enum JointGeometry {
    /// Ring radius (one source: `Joint.radius`).
    public static let ringRadius = Joint.radius
    /// Centre dot radius.
    public static let dotRadius = 0.35
    /// Stroke width of ring and marks.
    public static let strokeWidth = 0.3
    /// Accent blue of every joint mark; the ring is filled white.
    public static let accent = RGBAColor(r: 0, g: 0.48, b: 1)
    public static let ringFill = RGBAColor(r: 1, g: 1, b: 1)

    public static let groundHalfWidth = 1.8
    public static let groundDrop = 1.8
    public static let hatchLength = 0.6
    public static let lockHalfWidth = 1.2
    public static let lockHalfHeight = 0.9
    public static let shackleRadius = 0.6
    public static let shackleSegments = 8

    /// Ground mark below `position`: base line (3.6 mm wide, 1.8 mm below) and three hatch strokes under it.
    public static func groundMark(at position: Vec2) -> [[Vec2]] {
        let y = position.y + groundDrop
        var lines = [[Vec2(x: position.x - groundHalfWidth, y: y), Vec2(x: position.x + groundHalfWidth, y: y)]]
        for dx in [-1.2, 0, 1.2] {
            let top = Vec2(x: position.x + dx, y: y)
            lines.append([top, Vec2(x: top.x - hatchLength, y: y + hatchLength)])
        }
        return lines
    }

    /// Lock mark centred on `position`: 2.4 x 1.8 mm box and a shackle arc above it.
    public static func lockMark(at position: Vec2) -> [[Vec2]] {
        let (hw, hh) = (lockHalfWidth, lockHalfHeight)
        let box = [Vec2(x: position.x - hw, y: position.y - hh), Vec2(x: position.x + hw, y: position.y - hh),
                   Vec2(x: position.x + hw, y: position.y + hh), Vec2(x: position.x - hw, y: position.y + hh),
                   Vec2(x: position.x - hw, y: position.y - hh)]
        let top = position.y - hh
        let shackle = (0...shackleSegments).map { i -> Vec2 in
            let t = Double.pi * Double(i) / Double(shackleSegments)
            return Vec2(x: position.x + shackleRadius * cos(t), y: top - shackleRadius * sin(t))
        }
        return [box, shackle]
    }

    /// Polylines of the joint's line marks: the lock for `.fixed`, the ground mark for a grounded hinge.
    public static func marks(of joint: Joint) -> [[Vec2]] {
        switch joint.kind {
        case .fixed: lockMark(at: joint.position)
        case .hinge: joint.grounded ? groundMark(at: joint.position) : []
        }
    }
}
