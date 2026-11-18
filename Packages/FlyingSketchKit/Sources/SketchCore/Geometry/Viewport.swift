/// World (mm, y down) <-> view (points, origin top-left, y down) mapping.
public struct Viewport: Equatable, Codable, Sendable {
    /// World point (mm) shown at the view centre.
    public var center: Vec2
    public var zoom: Double

    public static let zoomRange = 0.05...32.0
    public static let pointsPerMillimetre = 160.0 / 25.4

    public init(center: Vec2, zoom: Double) {
        self.center = center
        self.zoom = zoom
    }

    /// Sanitises untrusted input: bad zoom -> 1 then clamped to `zoomRange`; non-finite centre -> `.zero`.
    public init(from decoder: Decoder) throws {
        enum Key: String, CodingKey { case center, zoom }
        let c = try decoder.container(keyedBy: Key.self)
        let rawCenter = try c.decode(Vec2.self, forKey: .center)
        let rawZoom = try c.decode(Double.self, forKey: .zoom)
        center = rawCenter.x.isFinite && rawCenter.y.isFinite ? rawCenter : .zero
        let z = rawZoom.isFinite && rawZoom > 0 ? rawZoom : 1
        zoom = min(max(z, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    private var scale: Double { zoom * Self.pointsPerMillimetre }

    public func worldToView(_ p: Vec2, viewSize: Vec2) -> Vec2 {
        (p - center) * scale + viewSize / 2
    }

    public func viewToWorld(_ p: Vec2, viewSize: Vec2) -> Vec2 {
        (p - viewSize / 2) / scale + center
    }

    public func visibleWorldRect(viewSize: Vec2) -> Rect {
        let half = viewSize / (2 * scale)
        return Rect(origin: center - half, size: half * 2)
    }

    /// Zooms by `factor` (result clamped to `zoomRange`), keeping the world point under `viewPoint` fixed.
    public mutating func zoom(by factor: Double, around viewPoint: Vec2, viewSize: Vec2) {
        let anchor = viewToWorld(viewPoint, viewSize: viewSize)
        zoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        center = anchor - (viewPoint - viewSize / 2) / scale
    }

    /// Content follows the finger: dragging right moves the centre left.
    public mutating func pan(byView delta: Vec2) {
        center = center - delta / scale
    }
}
