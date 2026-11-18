public enum WireAttachment: Hashable, Codable, Sendable {
    case connector(part: ObjectID, connector: String)
}

public struct WireEnd: Hashable, Codable, Sendable {
    /// Always the current world mm position.
    public var position: Vec2
    public var attachment: WireAttachment?

    public init(position: Vec2, attachment: WireAttachment? = nil) {
        self.position = position
        self.attachment = attachment
    }
}

public struct Wire: Hashable, Codable, Sendable {
    public var id: ObjectID
    public var start: WireEnd
    public var end: WireEnd
    public var bends: [Vec2]
    public var color: RGBAColor
    public var width: Double

    public init(id: ObjectID = .new(), start: WireEnd, end: WireEnd, bends: [Vec2] = [],
                color: RGBAColor = .black, width: Double = 0.65) {
        self.id = id
        self.start = start
        self.end = end
        self.bends = bends
        self.color = color
        self.width = width
    }

    /// start -> bends -> end.
    public var polyline: [Vec2] { [start.position] + bends + [end.position] }
}
