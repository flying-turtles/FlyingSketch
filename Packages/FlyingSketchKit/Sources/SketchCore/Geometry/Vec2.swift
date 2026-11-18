import Foundation

public struct Vec2: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(x: 0, y: 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(x: a.x * s, y: a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(x: a.x / s, y: a.y / s) }

    public var length: Double { (x * x + y * y).squareRoot() }

    /// Unit vector; `.zero` stays `.zero`.
    public var normalized: Vec2 {
        let l = length
        return l > 0 ? self / l : .zero
    }

    public func distance(to other: Vec2) -> Double { (self - other).length }

    public func rotated(by radians: Double) -> Vec2 {
        let c = cos(radians), s = sin(radians)
        return Vec2(x: x * c - y * s, y: x * s + y * c)
    }
}
