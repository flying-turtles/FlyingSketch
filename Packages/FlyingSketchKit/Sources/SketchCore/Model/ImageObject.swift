public struct ImageObject: Hashable, Codable, Sendable {
    public var id: ObjectID
    /// Key into `SketchDocument.assets`.
    public var assetName: String
    public var frame: Rect
    /// Radians.
    public var rotation: Double

    public init(id: ObjectID = .new(), assetName: String, frame: Rect, rotation: Double = 0) {
        self.id = id
        self.assetName = assetName
        self.frame = frame
        self.rotation = rotation
    }
}
