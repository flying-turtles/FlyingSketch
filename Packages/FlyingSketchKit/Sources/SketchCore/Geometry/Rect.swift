public struct Rect: Hashable, Codable, Sendable {
    public var origin: Vec2
    public var size: Vec2

    public init(origin: Vec2, size: Vec2) {
        self.origin = origin
        self.size = size
    }

    public var minX: Double { origin.x }
    public var maxX: Double { origin.x + size.x }
    public var minY: Double { origin.y }
    public var maxY: Double { origin.y + size.y }

    /// Edges inclusive.
    public func contains(_ p: Vec2) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    /// Touching edges count as intersecting.
    public func intersects(_ other: Rect) -> Bool {
        minX <= other.maxX && other.minX <= maxX && minY <= other.maxY && other.minY <= maxY
    }

    public func union(_ other: Rect) -> Rect {
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        let x1 = max(maxX, other.maxX), y1 = max(maxY, other.maxY)
        return Rect(origin: Vec2(x: x0, y: y0), size: Vec2(x: x1 - x0, y: y1 - y0))
    }

    public func insetBy(_ d: Double) -> Rect {
        Rect(origin: Vec2(x: origin.x + d, y: origin.y + d),
             size: Vec2(x: size.x - 2 * d, y: size.y - 2 * d))
    }

    public static func bounding(_ points: some Sequence<Vec2>) -> Rect? {
        var it = points.makeIterator()
        guard let first = it.next() else { return nil }
        var lo = first, hi = first
        while let p = it.next() {
            lo = Vec2(x: min(lo.x, p.x), y: min(lo.y, p.y))
            hi = Vec2(x: max(hi.x, p.x), y: max(hi.y, p.y))
        }
        return Rect(origin: lo, size: hi - lo)
    }
}
