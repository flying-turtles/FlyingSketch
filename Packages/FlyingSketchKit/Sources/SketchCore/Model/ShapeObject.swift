public enum ShapeKind: String, Codable, Sendable {
    case line, arrow, rectangle, ellipse
}

public struct ShapeObject: Hashable, Codable, Sendable {
    public var id: ObjectID
    public var kind: ShapeKind
    public var start: Vec2
    public var end: Vec2
    public var strokeColor: RGBAColor
    public var fillColor: RGBAColor?
    /// Millimetres.
    public var lineWidth: Double
    /// Radians, clockwise in the y-down world, about the box centre. Rectangles and ellipses only; lines and arrows ignore it.
    public var rotation: Double

    public init(id: ObjectID = .new(), kind: ShapeKind, start: Vec2, end: Vec2,
                strokeColor: RGBAColor = .black, fillColor: RGBAColor? = nil, lineWidth: Double = 0.5,
                rotation: Double = 0) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.lineWidth = lineWidth
        self.rotation = rotation
    }

    /// Files before format 3 have no `rotation`: decodes 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ObjectID.self, forKey: .id)
        kind = try c.decode(ShapeKind.self, forKey: .kind)
        start = try c.decode(Vec2.self, forKey: .start)
        end = try c.decode(Vec2.self, forKey: .end)
        strokeColor = try c.decode(RGBAColor.self, forKey: .strokeColor)
        fillColor = try c.decodeIfPresent(RGBAColor.self, forKey: .fillColor)
        lineWidth = try c.decode(Double.self, forKey: .lineWidth)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }
}
