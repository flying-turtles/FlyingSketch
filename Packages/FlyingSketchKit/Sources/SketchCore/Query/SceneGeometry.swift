import Foundation

public enum ShapeGeometry {
    /// Normalised bbox of `start`/`end`.
    public static func rect(of s: ShapeObject) -> Rect {
        Rect.bounding([s.start, s.end])!
    }

    /// Arrow head barb end points (mm). Nil for non-arrows and zero-length arrows.
    public static func arrowBarbs(of s: ShapeObject) -> (Vec2, Vec2)? {
        guard s.kind == .arrow else { return nil }
        let delta = s.end - s.start
        guard delta.length > 0 else { return nil }
        let dir = delta.normalized
        let head = max(s.lineWidth * 5, 4)
        let a = s.end + dir.rotated(by: .pi + 0.45) * head
        let b = s.end + dir.rotated(by: .pi - 0.45) * head
        return (a, b)
    }
}

extension Wire {
    /// Radius (mm) of the open circle marking a free wire end.
    public static let freeEndRadius: Double = 0.6
}

/// Union of object bounds, extended by arrow barbs and free wire-end circles. Nil for no objects.
public func contentBounds(of objects: [SceneObject], in doc: SketchDocument) -> Rect? {
    var result: Rect?
    func add(_ r: Rect) { result = result.map { $0.union(r) } ?? r }
    for object in objects {
        add(bounds(of: object, in: doc))
        switch object {
        case .shape(let s):
            if let (a, b) = ShapeGeometry.arrowBarbs(of: s) {
                add(Rect.bounding([a, b])!.insetBy(-s.lineWidth / 2))
            }
        case .wire(let w):
            let r = Wire.freeEndRadius + w.width / 2
            for end in [w.start, w.end] where end.attachment == nil {
                add(Rect(origin: Vec2(x: end.position.x - r, y: end.position.y - r), size: Vec2(x: 2 * r, y: 2 * r)))
            }
        default: break
        }
    }
    return result
}
