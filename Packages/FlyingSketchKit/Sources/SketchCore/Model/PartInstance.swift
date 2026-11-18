public struct PartInstance: Hashable, Codable, Sendable {
    public var id: ObjectID
    public var definitionKey: String
    public var center: Vec2
    /// Clockwise quarter turns (0...3) around `center`.
    public var quarterTurns: Int
    public var label: String
    public var properties: [String: String]
    /// connectorID -> world mm. Absent = leg at its default end.
    public var legEnds: [String: Vec2]

    public init(id: ObjectID = .new(), definitionKey: String, center: Vec2, quarterTurns: Int = 0,
                label: String = "", properties: [String: String] = [:], legEnds: [String: Vec2] = [:]) {
        self.id = id
        self.definitionKey = definitionKey
        self.center = center
        self.quarterTurns = quarterTurns
        self.label = label
        self.properties = properties
        self.legEnds = legEnds
    }

    /// Part-local mm (top-left origin) -> world mm, honouring `quarterTurns` around the centre.
    public func worldPoint(_ local: Vec2, in def: PartDefinition) -> Vec2 {
        let rel = local - def.size / 2
        let t = ((quarterTurns % 4) + 4) % 4
        let r: Vec2
        switch t {
        case 1: r = Vec2(x: -rel.y, y: rel.x)
        case 2: r = Vec2(x: -rel.x, y: -rel.y)
        case 3: r = Vec2(x: rel.y, y: -rel.x)
        default: r = rel
        }
        return center + r
    }

    /// Axis-aligned world rect of the body (size swapped for odd turns).
    public func bodyRect(in def: PartDefinition) -> Rect {
        let odd = quarterTurns % 2 != 0
        let size = odd ? Vec2(x: def.size.y, y: def.size.x) : def.size
        return Rect(origin: center - size / 2, size: size)
    }

    /// World leg segment (origin, end) of a connector that has a leg.
    public func legSegment(for c: ConnectorDef, in def: PartDefinition) -> (origin: Vec2, end: Vec2)? {
        guard let leg = c.leg else { return nil }
        return (worldPoint(leg.origin, in: def), legEnds[c.id] ?? worldPoint(leg.defaultEnd, in: def))
    }
}
