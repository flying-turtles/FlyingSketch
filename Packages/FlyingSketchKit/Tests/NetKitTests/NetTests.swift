import Testing
import SketchCore
@testable import NetKit

private struct Fix {
    var doc = SketchDocument()
    let res = PartDefinition.fixtureResistor()
    let board = PartDefinition.fixtureBreadboardMini()
    let module = PartDefinition.fixtureModule()

    init() { for d in [res, board, module] { doc.parts[d.key] = d } }

    mutating func add(_ d: PartDefinition, at c: Vec2, label: String, legEnds: [String: Vec2] = [:]) -> ObjectID {
        let p = PartInstance(definitionKey: d.key, center: c, label: label, legEnds: legEnds)
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

@Test func wireJoinsTwoPins() {
    var f = Fix()
    let r1 = f.add(f.res, at: Vec2(x: 0, y: 0), label: "R1")
    let r2 = f.add(f.res, at: Vec2(x: 0, y: 50), label: "R2")
    let w = f.wire((r1, "b"), (r2, "a"))
    let ns = nets(in: f.doc)
    #expect(ns.count == 1)
    #expect(ns[0].members == [ConnectorRef(part: r1, connector: "b"), ConnectorRef(part: r2, connector: "a")])
    #expect(ns[0].wires == [w])
    #expect(ns[0].name == "N1")
    #expect(ns[0].id == 1)
}

@Test func breadboardBusJoinsColumn() {
    var f = Fix()
    let bb = f.add(f.board, at: Vec2(x: 0, y: 0), label: "BB1")
    // board origin = (-6.35, -7.62); c0r0 at (-3.81, -5.08), c0r1 at (-3.81, -2.54)
    let r1 = f.add(f.res, at: Vec2(x: 100, y: 100), label: "R1", legEnds: ["a": Vec2(x: -3.81, y: -5.08), "b": Vec2(x: 20, y: 20)])
    let r2 = f.add(f.res, at: Vec2(x: 100, y: 200), label: "R2", legEnds: ["a": Vec2(x: -3.81, y: -2.54), "b": Vec2(x: 30, y: 30)])
    let ns = nets(in: f.doc)
    #expect(ns.count == 1)
    let n = ns[0]
    #expect(n.wires.isEmpty)
    #expect(n.members.contains(ConnectorRef(part: r1, connector: "a")))
    #expect(n.members.contains(ConnectorRef(part: r2, connector: "a")))
    #expect(n.members.contains(ConnectorRef(part: bb, connector: "c0r4")))
    #expect(n.members.count == 7)
    #expect(net(containing: ConnectorRef(part: r1, connector: "a"), in: ns) == n)
    #expect(net(containing: ConnectorRef(part: r1, connector: "b"), in: ns) == nil)
}

@Test func chainedWiresMerge() {
    var f = Fix()
    let r1 = f.add(f.res, at: .zero, label: "R1")
    let r2 = f.add(f.res, at: Vec2(x: 0, y: 20), label: "R2")
    let r3 = f.add(f.res, at: Vec2(x: 0, y: 40), label: "R3")
    let w1 = f.wire((r1, "b"), (r2, "a"))
    let w2 = f.wire((r2, "a"), (r3, "a"))
    let ns = nets(in: f.doc)
    #expect(ns.count == 1)
    #expect(ns[0].members.count == 3)
    #expect(ns[0].wires == [w1, w2])
}

@Test func groundNetNamedGND() {
    var f = Fix()
    let m1 = f.add(f.module, at: .zero, label: "U1")
    let m2 = f.add(f.module, at: Vec2(x: 0, y: 50), label: "U2")
    f.wire((m1, "GND"), (m2, "gnd"))
    f.wire((m1, "VCC"), (m2, "VCC"))
    f.wire((m1, "SDA"), (m2, "SCL"))
    let ns = nets(in: f.doc)
    #expect(ns.count == 3)
    #expect(Set(ns.map(\.name)) == ["GND", "VCC", "N1"])
    #expect(ns.map(\.id) == [1, 2, 3])
}

@Test func mixedRoleNamesFallBackToN() {
    var f = Fix()
    let m1 = f.add(f.module, at: .zero, label: "U1")
    let m2 = f.add(f.module, at: Vec2(x: 0, y: 50), label: "U2")
    f.wire((m1, "GND"), (m2, "VCC"))
    #expect(nets(in: f.doc).map(\.name) == ["N1"])
}

@Test func twoGroundNetsKeepName() {
    var f = Fix()
    let m1 = f.add(f.module, at: .zero, label: "U1")
    let m2 = f.add(f.module, at: Vec2(x: 0, y: 50), label: "U2")
    let m3 = f.add(f.module, at: Vec2(x: 0, y: 100), label: "U3")
    f.wire((m1, "GND"), (m2, "GND"))
    f.wire((m3, "GND"), (m3, "GND"))
    f.wire((m3, "SDA"), nil)
    let ns = nets(in: f.doc)
    #expect(ns.map(\.name).filter { $0 == "GND" }.count == 2)
    #expect(ns.map(\.name).contains("N1"))
}

@Test func danglingWireBelongsToNet() {
    var f = Fix()
    let r1 = f.add(f.res, at: .zero, label: "R1")
    let w = f.wire((r1, "a"), nil)
    f.wire(nil, nil)
    let ns = nets(in: f.doc)
    #expect(ns.count == 1)
    #expect(ns[0].members == [ConnectorRef(part: r1, connector: "a")])
    #expect(ns[0].wires == [w])
}

@Test func unconnectedPinsHaveNoNet() {
    var f = Fix()
    _ = f.add(f.res, at: .zero, label: "R1")
    _ = f.add(f.board, at: Vec2(x: 50, y: 0), label: "BB1")
    #expect(nets(in: f.doc).isEmpty)
}

@Test func stableNamesAcrossRecompute() {
    var f = Fix()
    let r1 = f.add(f.res, at: .zero, label: "R1")
    let r2 = f.add(f.res, at: Vec2(x: 0, y: 20), label: "R2")
    let r3 = f.add(f.res, at: Vec2(x: 0, y: 40), label: "R3")
    f.wire((r3, "b"), (r2, "b"))
    f.wire((r1, "a"), (r2, "a"))
    let first = nets(in: f.doc)
    #expect(first == nets(in: f.doc))
    #expect(first.map(\.name) == ["N1", "N2"])
    // R1.a/R2.a net sorts first (label R1 < R2).
    #expect(first[0].members.contains(ConnectorRef(part: r1, connector: "a")))
}

@Test func netsFor500PartsUnder50ms() {
    var f = Fix()
    // 25 boards in a 5x5 grid; 20 resistors per board stand on columns (4 columns x 5 rows of holes).
    var count = 0
    for bx in 0..<5 {
        for by in 0..<5 {
            let c = Vec2(x: Double(bx) * 40, y: Double(by) * 40)
            _ = f.add(f.board, at: c, label: "BB\(bx * 5 + by)")
            let o = c - Vec2(x: 6.35, y: 7.62)
            for i in 0..<20 {
                let col = i % 4, row = i / 4
                let hole = o + Vec2(x: 2.54 + Double(col) * 2.54, y: 2.54 + Double(row) * 2.54)
                count += 1
                _ = f.add(f.res, at: Vec2(x: 1000 + Double(count) * 20, y: 1000), label: "R\(count)",
                          legEnds: ["a": hole, "b": Vec2(x: 5000 + Double(count), y: 5000)])
            }
        }
    }
    #expect(count == 500)
    let clock = ContinuousClock()
    var result: [Net] = []
    let t = clock.measure { result = nets(in: f.doc) }
    print("nets(500 resistors) took \(t)")
    #expect(result.count == 100)
    #expect(t < .milliseconds(50))
}
