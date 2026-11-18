public enum InkTool: String, Codable, Sendable {
    case pen, pencil, marker, highlighter
}

public struct InkPoint: Hashable, Codable, Sendable {
    public var position: Vec2
    /// 0...1
    public var pressure: Double
    public var altitude: Double?
    public var azimuth: Double?
    /// Seconds since stroke start.
    public var time: Double

    public init(position: Vec2, pressure: Double, altitude: Double? = nil, azimuth: Double? = nil, time: Double) {
        self.position = position
        self.pressure = pressure
        self.altitude = altitude
        self.azimuth = azimuth
        self.time = time
    }
}

public struct InkStroke: Hashable, Codable, Sendable {
    public var id: ObjectID
    public var points: [InkPoint]
    public var tool: InkTool
    public var color: RGBAColor
    /// Millimetres.
    public var baseWidth: Double

    public init(id: ObjectID = .new(), points: [InkPoint], tool: InkTool = .pen, color: RGBAColor = .black, baseWidth: Double = 0.5) {
        self.id = id
        self.points = points
        self.tool = tool
        self.color = color
        self.baseWidth = baseWidth
    }
}
