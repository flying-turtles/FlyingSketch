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

    public init(id: ObjectID = .new(), kind: ShapeKind, start: Vec2, end: Vec2,
                strokeColor: RGBAColor = .black, fillColor: RGBAColor? = nil, lineWidth: Double = 0.5) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.lineWidth = lineWidth
    }
}
