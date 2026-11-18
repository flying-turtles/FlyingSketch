import Foundation

/// Rounds each coordinate to the nearest multiple of `grid` (mm). Non-positive grid returns `p` unchanged.
public func snap(_ p: Vec2, grid: Double) -> Vec2 {
    guard grid > 0 else { return p }
    return Vec2(x: (p.x / grid).rounded() * grid, y: (p.y / grid).rounded() * grid)
}
