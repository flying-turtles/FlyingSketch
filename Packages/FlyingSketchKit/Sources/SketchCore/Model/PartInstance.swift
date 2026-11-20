public struct PartInstance: Hashable, Codable, Sendable {
    public var id: ObjectID
    public var definitionKey: String
    public var center: Vec2
    /// Clockwise radians around `center`, normalised to [0, 2π) via `normalizedAngle`.
    public var rotation: Double
    public var label: String
    public var properties: [String: String]
    /// connectorID -> world mm. Absent = leg at its default end.
    public var legEnds: [String: Vec2]

    public init(id: ObjectID = .new(), definitionKey: String, center: Vec2, rotation: Double = 0,
                label: String = "", properties: [String: String] = [:], legEnds: [String: Vec2] = [:]) {
        self.id = id
        self.definitionKey = definitionKey
        self.center = center
        self.rotation = rotation
        self.label = label
        self.properties = properties
        self.legEnds = legEnds
    }

    private enum CodingKeys: String, CodingKey {
        case id, definitionKey, center, rotation, quarterTurns, label, properties, legEnds
    }

    /// Format <= 2 stored `quarterTurns`; a part without `rotation` decodes it as `quarterTurns` x π/2.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ObjectID.self, forKey: .id)
        definitionKey = try c.decode(String.self, forKey: .definitionKey)
        center = try c.decode(Vec2.self, forKey: .center)
        if let r = try c.decodeIfPresent(Double.self, forKey: .rotation) {
            rotation = normalizedAngle(r)
        } else {
            rotation = normalizedAngle(Double(try c.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0) * .pi / 2)
        }
        label = try c.decode(String.self, forKey: .label)
        properties = try c.decode([String: String].self, forKey: .properties)
        legEnds = try c.decode([String: Vec2].self, forKey: .legEnds)
    }

    /// Writes `rotation` only (no `quarterTurns`).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(definitionKey, forKey: .definitionKey)
        try c.encode(center, forKey: .center)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(label, forKey: .label)
        try c.encode(properties, forKey: .properties)
        try c.encode(legEnds, forKey: .legEnds)
    }

    /// Part-local mm (top-left origin) -> world mm, rotating clockwise by `rotation` around the centre.
    /// Quarter turns take an exact integer path.
    public func worldPoint(_ local: Vec2, in def: PartDefinition) -> Vec2 {
        let rel = local - def.size / 2
        guard let q = quarterTurns(of: rotation) else { return center + rel.rotated(by: rotation) }
        let r: Vec2
        switch q {
        case 1: r = Vec2(x: -rel.y, y: rel.x)
        case 2: r = Vec2(x: -rel.x, y: -rel.y)
        case 3: r = Vec2(x: rel.y, y: -rel.x)
        default: r = rel
        }
        return center + r
    }

    /// Inverse of `worldPoint`: world mm -> part-local mm.
    public func localPoint(_ world: Vec2, in def: PartDefinition) -> Vec2 {
        let rel = world - center
        let r: Vec2
        if let q = quarterTurns(of: rotation) {
            switch q {
            case 1: r = Vec2(x: rel.y, y: -rel.x)
            case 2: r = Vec2(x: -rel.x, y: -rel.y)
            case 3: r = Vec2(x: -rel.y, y: rel.x)
            default: r = rel
            }
        } else {
            r = rel.rotated(by: -rotation)
        }
        return r + def.size / 2
    }

    /// World corners of the body: local top-left, top-right, bottom-right, bottom-left.
    public func bodyCorners(in def: PartDefinition) -> [Vec2] {
        let (w, h) = (def.size.x, def.size.y)
        return [Vec2(x: 0, y: 0), Vec2(x: w, y: 0), Vec2(x: w, y: h), Vec2(x: 0, y: h)].map { worldPoint($0, in: def) }
    }

    /// World leg segment (origin, end) of a connector that has a leg.
    public func legSegment(for c: ConnectorDef, in def: PartDefinition) -> (origin: Vec2, end: Vec2)? {
        guard let leg = c.leg else { return nil }
        return (worldPoint(leg.origin, in: def), legEnds[c.id] ?? worldPoint(leg.defaultEnd, in: def))
    }
}
