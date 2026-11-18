public struct ConnectorRef: Hashable, Sendable {
    public var part: ObjectID
    public var connector: String

    public init(part: ObjectID, connector: String) {
        self.part = part
        self.connector = connector
    }
}

public struct Contact: Hashable, Sendable {
    public var male: ConnectorRef
    public var female: ConnectorRef

    public init(male: ConnectorRef, female: ConnectorRef) {
        self.male = male
        self.female = female
    }
}

/// Plug snap search radius (mm).
let plugSnapRadius = 1.0
/// Male-in-female contact tolerance (mm).
let contactTolerance = 0.2

/// Female connector positions bucketed in a uniform grid (cell = one breadboard pitch) so lookups touch
/// only neighbouring cells instead of every pin.
struct FemaleIndex {
    private struct Cell: Hashable { var x: Int; var y: Int }
    private struct Entry { var ref: ConnectorRef; var position: Vec2 }

    /// Distances closer than this are ties, resolved by `precedes` so results never depend on hash order.
    static let tieEpsilon = 1e-9
    private static let cellSize = 2.54

    static func precedes(_ a: ConnectorRef, _ b: ConnectorRef) -> Bool {
        let (pa, pb) = (a.part.raw.uuidString, b.part.raw.uuidString)
        return pa != pb ? pa < pb : a.connector < b.connector
    }
    private var cells: [Cell: [Entry]] = [:]

    init(_ doc: SketchDocument, excluding: Set<ObjectID> = []) {
        for case .part(let p) in doc.objects where !excluding.contains(p.id) {
            guard let def = doc.parts[p.definitionKey] else { continue }
            let positions = connectorPositions(p, def)
            for c in def.connectors where c.kind == .female {
                guard let pos = positions[c.id] else { continue }
                cells[Self.cell(of: pos), default: []].append(Entry(ref: ConnectorRef(part: p.id, connector: c.id), position: pos))
            }
        }
    }

    private static func cell(of p: Vec2) -> Cell {
        Cell(x: Int((p.x / cellSize).rounded(.down)), y: Int((p.y / cellSize).rounded(.down)))
    }

    /// Nearest female within `radius` of `p` (radius must be <= cell size).
    func nearest(to p: Vec2, within radius: Double, excluding part: ObjectID? = nil) -> (ref: ConnectorRef, position: Vec2)? {
        let c = Self.cell(of: p)
        var best: (ref: ConnectorRef, position: Vec2, d: Double)?
        for dx in -1...1 {
            for dy in -1...1 {
                for e in cells[Cell(x: c.x + dx, y: c.y + dy)] ?? [] where e.ref.part != part {
                    let d = e.position.distance(to: p)
                    guard d <= radius else { continue }
                    if let b = best, d > b.d + Self.tieEpsilon || (abs(d - b.d) <= Self.tieEpsilon && !Self.precedes(e.ref, b.ref)) { continue }
                    best = (e.ref, e.position, d)
                }
            }
        }
        return best.map { ($0.ref, $0.position) }
    }
}

/// Male connectors within `contactTolerance` (0.2 mm) of a female on a different part.
public func contacts(in doc: SketchDocument) -> Set<Contact> {
    let index = FemaleIndex(doc)
    var result: Set<Contact> = []
    for case .part(let p) in doc.objects {
        guard let def = doc.parts[p.definitionKey] else { continue }
        let positions = connectorPositions(p, def)
        for c in def.connectors where c.kind == .male {
            guard let pos = positions[c.id],
                  let hit = index.nearest(to: pos, within: contactTolerance, excluding: p.id) else { continue }
            result.insert(Contact(male: ConnectorRef(part: p.id, connector: c.id), female: hit.ref))
        }
    }
    return result
}

/// Nearest female connector (<= 1.0 mm) of a part other than `part` to world point `p`; nil if none.
public func nearestFemale(to p: Vec2, in doc: SketchDocument, excluding part: ObjectID) -> (ref: ConnectorRef, position: Vec2)? {
    FemaleIndex(doc, excluding: [part]).nearest(to: p, within: plugSnapRadius)
}

/// Smallest offset (<= 1.0 mm) that puts a male connector of `instance` exactly on a female of a part not in
/// `excluding` (the instance itself is always ignored); nil if none.
public func plugSnapOffset(for instance: PartInstance, in doc: SketchDocument, excluding: Set<ObjectID>) -> Vec2? {
    guard let def = doc.parts[instance.definitionKey] else { return nil }
    let index = FemaleIndex(doc, excluding: excluding.union([instance.id]))
    var best: (offset: Vec2, d: Double)?
    let positions = connectorPositions(instance, def)
    // Declaration order + epsilon ties: first connector wins, so the result is stable across launches.
    for c in def.connectors where c.kind == .male {
        guard let pos = positions[c.id], let hit = index.nearest(to: pos, within: plugSnapRadius) else { continue }
        let offset = hit.position - pos
        let d = offset.length
        if d < (best?.d ?? .infinity) - FemaleIndex.tieEpsilon { best = (offset, d) }
    }
    return best?.offset
}

/// Transitive closure of parts whose male connectors are plugged into a female of a moving (or carried) part.
/// The result excludes `moving` itself.
public func carriedParts(by moving: Set<ObjectID>, in doc: SketchDocument) -> Set<ObjectID> {
    var carriedBy: [ObjectID: [ObjectID]] = [:]
    for c in contacts(in: doc) { carriedBy[c.female.part, default: []].append(c.male.part) }
    var result: Set<ObjectID> = []
    var frontier = Array(moving)
    while let id = frontier.popLast() {
        for child in carriedBy[id] ?? [] where !moving.contains(child) && result.insert(child).inserted {
            frontier.append(child)
        }
    }
    return result
}
