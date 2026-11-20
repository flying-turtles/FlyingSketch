/// Kind of mechanical joint.
public enum JointKind: String, Codable, Sendable {
    /// Shared pivot of 1...n bodies; optionally `grounded` (fixed to the background at `position`).
    case hinge
    /// "Lock in place": exactly one anchor, always `grounded`.
    case fixed
}

/// One body's copy of a pin point, in world mm. Starts equal to `Joint.position`; later moves only with its own body.
public struct JointAnchor: Hashable, Codable, Sendable {
    public var object: ObjectID
    public var point: Vec2

    public init(object: ObjectID, point: Vec2) {
        self.object = object
        self.point = point
    }
}

/// A pin between drawn objects. Wires are never anchors.
public struct Joint: Hashable, Codable, Sendable {
    public var id: ObjectID
    public var kind: JointKind
    /// Display position; the fixed world point when `grounded`.
    public var position: Vec2
    public var anchors: [JointAnchor]
    public var grounded: Bool

    /// Drawn radius, mm.
    public static let radius = 1.2

    public init(id: ObjectID = .new(), kind: JointKind = .hinge, position: Vec2,
                anchors: [JointAnchor] = [], grounded: Bool = false) {
        self.id = id
        self.kind = kind
        self.position = position
        self.anchors = anchors
        self.grounded = grounded
    }
}
