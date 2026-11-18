public struct TextObject: Hashable, Codable, Sendable {
    public var id: ObjectID
    public var text: String
    public var position: Vec2
    /// Millimetres.
    public var fontSize: Double
    /// Radians.
    public var rotation: Double
    public var color: RGBAColor

    public init(id: ObjectID = .new(), text: String, position: Vec2, fontSize: Double = 6,
                rotation: Double = 0, color: RGBAColor = .black) {
        self.id = id
        self.text = text
        self.position = position
        self.fontSize = fontSize
        self.rotation = rotation
        self.color = color
    }
}
