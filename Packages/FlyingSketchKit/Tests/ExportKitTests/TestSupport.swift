import SketchCore

struct Fix {
    var doc = SketchDocument()
    let res = PartDefinition.fixtureResistor()
    let board = PartDefinition.fixtureBreadboardMini()
    let module = PartDefinition.fixtureModule()

    init() { for d in [res, board, module] { doc.parts[d.key] = d } }

    @discardableResult
    mutating func add(_ d: PartDefinition, at c: Vec2 = .zero, label: String = "", properties: [String: String] = [:],
                      quarterTurns: Int = 0, legEnds: [String: Vec2] = [:]) -> ObjectID {
        let p = PartInstance(definitionKey: d.key, center: c, quarterTurns: quarterTurns, label: label,
                             properties: properties, legEnds: legEnds)
        doc.objects.append(.part(p))
        return p.id
    }

    @discardableResult
    mutating func wire(_ a: (ObjectID, String)?, _ b: (ObjectID, String)?) -> ObjectID {
        func end(_ x: (ObjectID, String)?) -> WireEnd {
            WireEnd(position: .zero, attachment: x.map { .connector(part: $0.0, connector: $0.1) })
        }
        let w = Wire(start: end(a), end: end(b))
        doc.objects.append(.wire(w))
        return w.id
    }
}
