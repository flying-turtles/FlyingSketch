import SketchCore

public struct Net: Hashable, Sendable {
    public var id: Int
    public var name: String
    public var members: Set<ConnectorRef>
    public var wires: Set<ObjectID>

    public init(id: Int, name: String, members: Set<ConnectorRef>, wires: Set<ObjectID>) {
        self.id = id
        self.name = name
        self.members = members
        self.wires = wires
    }
}

/// Union-find with path compression over dense indices.
private struct DisjointSets {
    private var parent: [Int] = []

    mutating func add() -> Int {
        parent.append(parent.count)
        return parent.count - 1
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var cur = x
        while parent[cur] != root { (parent[cur], cur) = (root, parent[cur]) }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let (ra, rb) = (find(a), find(b))
        if ra != rb { parent[rb] = ra }
    }
}

/// Electrical nets of `doc`. Connectors join via wires, plugged contacts and part buses. A bus only counts
/// once one of its connectors is wired or plugged (an empty breadboard has no nets). A net needs >= 2 members
/// or >= 1 wire. Order and ids are deterministic: nets sorted by their smallest (part label, connector name),
/// ids 1...n in that order.
public func nets(in doc: SketchDocument) -> [Net] {
    var sets = DisjointSets()
    var indexOf: [ConnectorRef: Int] = [:]
    var refs: [ConnectorRef] = []
    var sortKeys: [SortKey] = []

    var parts: [ObjectID: (PartInstance, PartDefinition)] = [:]
    for case .part(let p) in doc.objects {
        if let def = doc.parts[p.definitionKey] { parts[p.id] = (p, def) }
    }

    func node(_ ref: ConnectorRef) -> Int? {
        if let i = indexOf[ref] { return i }
        guard let (p, def) = parts[ref.part], let c = def.connectors.first(where: { $0.id == ref.connector }) else { return nil }
        let i = sets.add()
        indexOf[ref] = i
        refs.append(ref)
        sortKeys.append(SortKey(label: p.label, name: c.name, id: c.id, part: p.id.raw.uuidString))
        return i
    }

    // (wire id, node of attached ends)
    var wireNodes: [(ObjectID, [Int])] = []
    for case .wire(let w) in doc.objects {
        var ns: [Int] = []
        for end in [w.start, w.end] {
            guard case .connector(let part, let connector)? = end.attachment,
                  let n = node(ConnectorRef(part: part, connector: connector)) else { continue }
            ns.append(n)
        }
        for n in ns.dropFirst() { sets.union(ns[0], n) }
        wireNodes.append((w.id, ns))
    }

    for c in contacts(in: doc) {
        if let m = node(c.male), let f = node(c.female) { sets.union(m, f) }
    }

    // Buses: only those that already have an active connector.
    let activeParts = Set(refs.map(\.part))
    for part in activeParts {
        guard let (_, def) = parts[part] else { continue }
        for bus in def.buses {
            let known = bus.compactMap { indexOf[ConnectorRef(part: part, connector: $0)] }
            guard let first = known.first else { continue }
            for id in bus {
                if let n = node(ConnectorRef(part: part, connector: id)) { sets.union(first, n) }
            }
        }
    }

    var membersByRoot: [Int: [Int]] = [:]
    for i in refs.indices { membersByRoot[sets.find(i), default: []].append(i) }
    var wiresByRoot: [Int: Set<ObjectID>] = [:]
    for (id, ns) in wireNodes {
        guard let n = ns.first else { continue }
        wiresByRoot[sets.find(n), default: []].insert(id)
    }

    struct Draft { var key: SortKey; var members: [Int]; var wires: Set<ObjectID> }
    let drafts: [Draft] = membersByRoot.compactMap { root, members in
        let wires = wiresByRoot[root] ?? []
        guard members.count >= 2 || !wires.isEmpty else { return nil }
        return Draft(key: members.map { sortKeys[$0] }.min()!, members: members, wires: wires)
    }.sorted { $0.key < $1.key }

    var unnamed = 0
    return drafts.enumerated().map { offset, d in
        let memberRefs = Set(d.members.map { refs[$0] })
        let name = powerGroundName(d.members.map { refs[$0] }, parts: parts) ?? {
            unnamed += 1
            return "N\(unnamed)"
        }()
        return Net(id: offset + 1, name: name, members: memberRefs, wires: d.wires)
    }
}

public func net(containing ref: ConnectorRef, in nets: [Net]) -> Net? {
    nets.first { $0.members.contains(ref) }
}

private struct SortKey: Comparable {
    var label: String
    var name: String
    var id: String
    var part: String

    static func < (a: SortKey, b: SortKey) -> Bool {
        if a.label != b.label { return a.label < b.label }
        if a.name != b.name { return a.name < b.name }
        if a.id != b.id { return a.id < b.id }
        return a.part < b.part
    }
}

/// Shared connector name of the power/ground members (case-insensitive, first spelling wins), else nil.
private func powerGroundName(_ members: [ConnectorRef], parts: [ObjectID: (PartInstance, PartDefinition)]) -> String? {
    var found: [(SortKey, String)] = []
    for ref in members {
        guard let (p, def) = parts[ref.part], let c = def.connectors.first(where: { $0.id == ref.connector }),
              c.role == .power || c.role == .ground else { continue }
        found.append((SortKey(label: p.label, name: c.name, id: c.id, part: p.id.raw.uuidString), c.name))
    }
    guard !found.isEmpty else { return nil }
    found.sort { $0.0 < $1.0 }
    let first = found[0].1
    return found.allSatisfy { $0.1.lowercased() == first.lowercased() } ? first : nil
}
