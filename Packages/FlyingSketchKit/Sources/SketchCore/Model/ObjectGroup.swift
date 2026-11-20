/// Objects that move as one rigid body. Lives in `SketchDocument.groups`, not in `objects`.
public struct ObjectGroup: Hashable, Codable, Sendable {
    public var id: ObjectID
    public var members: [ObjectID]

    public init(id: ObjectID = .new(), members: [ObjectID] = []) {
        self.id = id
        self.members = members
    }
}

/// The body `object` belongs to: its group's id, else the object's own id.
public func bodyID(of object: ObjectID, in doc: SketchDocument) -> ObjectID {
    doc.groups.first { $0.members.contains(object) }?.id ?? object
}

/// Objects making up `body`: the group's members, or `[body]` when it is not a group.
public func bodyMembers(_ body: ObjectID, in doc: SketchDocument) -> [ObjectID] {
    doc.groups.first { $0.id == body }?.members ?? [body]
}
