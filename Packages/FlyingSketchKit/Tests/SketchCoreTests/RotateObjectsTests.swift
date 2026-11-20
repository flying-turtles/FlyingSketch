import Foundation
import Testing
@testable import SketchCore

private let resistorDef = PartDefinition.fixtureResistor()
private let boardDef = PartDefinition.fixtureBreadboardMini()
private let moduleDef = PartDefinition.fixtureModule()

private func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-9) -> Bool { a.distance(to: b) <= tol }

private func rotatedObject(_ o: SceneObject, _ angle: Double, _ pivot: Vec2 = .zero) -> SceneObject {
    o.rotated(by: angle, around: pivot)
}

@Test func rotatedInkAndLine() {
    let stroke = InkStroke(points: [InkPoint(position: Vec2(x: 10, y: 0), pressure: 1, altitude: nil, azimuth: nil, time: 0)],
                           tool: .pen, color: .black, baseWidth: 0.5)
    guard case .ink(let ink) = rotatedObject(.ink(stroke), .pi / 2) else { Issue.record("not ink"); return }
    #expect(near(ink.points[0].position, Vec2(x: 0, y: 10)))
    let line = ShapeObject(kind: .line, start: .zero, end: Vec2(x: 10, y: 0))
    guard case .shape(let l) = rotatedObject(.shape(line), .pi / 2) else { Issue.record("not shape"); return }
    #expect(near(l.start, .zero) && near(l.end, Vec2(x: 0, y: 10)))
    #expect(l.rotation == 0)
}

@Test func rotatedRectKeepsSize() {
    let r = ShapeObject(kind: .rectangle, start: .zero, end: Vec2(x: 20, y: 10))
    guard case .shape(let out) = rotatedObject(.shape(r), .pi / 2) else { Issue.record("not shape"); return }
    #expect(near(ShapeGeometry.center(of: out), Vec2(x: -5, y: 10)))
    let size = out.end - out.start
    #expect(abs(size.x) == 20 && abs(size.y) == 10)
    #expect(out.rotation == .pi / 2)
}

@Test func rotatedTextAndImage() {
    let t = TextObject(text: "x", position: Vec2(x: 10, y: 0), fontSize: 8, rotation: 0.2)
    guard case .text(let tt) = rotatedObject(.text(t), 0.3) else { Issue.record("not text"); return }
    #expect(near(tt.position, Vec2(x: 10, y: 0).rotated(by: 0.3)))
    #expect(abs(tt.rotation - 0.5) < 1e-9)
    let img = ImageObject(assetName: "a.png", frame: Rect(origin: .zero, size: Vec2(x: 10, y: 10)))
    guard case .image(let i) = rotatedObject(.image(img), .pi) else { Issue.record("not image"); return }
    #expect(near(i.frame.origin, Vec2(x: -10, y: -10)))
    #expect(i.frame.size == Vec2(x: 10, y: 10))
    #expect(i.rotation == .pi)
}

@Test func rotatedPartMovesLegEnds() {
    let r = PartInstance(definitionKey: resistorDef.key, center: Vec2(x: 5, y: 7), legEnds: ["a": Vec2(x: -20, y: 10)])
    guard case .part(let p) = rotatedObject(.part(r), .pi / 2, r.center) else { Issue.record("not part"); return }
    #expect(near(p.center, r.center))
    #expect(near(p.legEnds["a"]!, r.center + (Vec2(x: -20, y: 10) - r.center).rotated(by: .pi / 2)))
    #expect(p.rotation == .pi / 2)
}

@Test func fullTurnIsIdentityForQuarterSteps() {
    var objects = SketchDocument.fixtureWithEveryKind().objects + SketchDocument.fixtureWithPartsAndWire().objects
    objects.append(.shape(ShapeObject(kind: .ellipse, start: Vec2(x: 3, y: 4), end: Vec2(x: 13, y: 9))))
    let pivot = Vec2(x: 7, y: -3)
    for o in objects {
        var cur = o
        for _ in 0..<4 { cur = cur.rotated(by: .pi / 2, around: pivot) }
        if case .part(let p) = cur, case .part(let orig) = o {
            #expect(p.rotation == orig.rotation)
            #expect(near(p.center, orig.center))
            for (k, v) in orig.legEnds { #expect(near(p.legEnds[k]!, v)) }
        } else if case .shape(let s) = cur, case .shape(let orig) = o {
            #expect(near(s.start, orig.start) && near(s.end, orig.end) && abs(s.rotation - orig.rotation) < 1e-9)
        } else if case .text(let t) = cur, case .text(let orig) = o {
            #expect(near(t.position, orig.position) && abs(t.rotation - orig.rotation) < 1e-9)
        } else if case .image(let i) = cur, case .image(let orig) = o {
            #expect(near(i.frame.origin, orig.frame.origin) && abs(i.rotation - normalizedAngle(orig.rotation)) < 1e-9)
        } else if case .ink(let i) = cur, case .ink(let orig) = o {
            for (a, b) in zip(i.points, orig.points) { #expect(near(a.position, b.position)) }
        } else if case .wire(let w) = cur, case .wire(let orig) = o {
            #expect(near(w.start.position, orig.start.position) && near(w.end.position, orig.end.position))
            for (a, b) in zip(w.bends, orig.bends) { #expect(near(a, b)) }
        } else {
            Issue.record("kind mismatch")
        }
    }
}

// Board with a module plugged in, wireA (not rotated) and wireB (rotated) attached to module pins.
private struct Scene {
    var doc: SketchDocument
    var board: PartInstance
    var module: PartInstance
    var wireA: Wire
    var wireB: Wire
}

private func scene() -> Scene {
    let board = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 40, y: 0))
    var module = PartInstance(definitionKey: moduleDef.key, center: Vec2(x: 40, y: 0))
    let hole = connectorPositions(board, boardDef)["c0r1"]!
    module.center = module.center + (hole - connectorPositions(module, moduleDef)["VCC"]!)
    let pins = connectorPositions(module, moduleDef)
    let a = Wire(start: WireEnd(position: pins["SCL"]!, attachment: .connector(part: module.id, connector: "SCL")),
                 end: WireEnd(position: Vec2(x: 70, y: 20)), bends: [Vec2(x: 60, y: 10)])
    let b = Wire(start: WireEnd(position: pins["GND"]!, attachment: .connector(part: module.id, connector: "GND")),
                 end: WireEnd(position: Vec2(x: 60, y: 30)), bends: [Vec2(x: 50, y: 20)])
    let doc = SketchDocument(objects: [.part(board), .part(module), .wire(a), .wire(b)],
                             parts: [boardDef.key: boardDef, moduleDef.key: moduleDef])
    return Scene(doc: doc, board: board, module: module, wireA: a, wireB: b)
}

private func applied(_ edits: [SceneObject], to doc: SketchDocument) -> SketchDocument {
    var out = doc
    for e in edits { if let i = out.objects.firstIndex(where: { $0.id == e.id }) { out.objects[i] = e } }
    return out
}

@Test func rotateObjectsCarriesPluggedParts() {
    let s = scene()
    #expect(!contacts(in: s.doc).isEmpty)
    let edits = rotateObjects([s.board.id], by: .pi / 2, around: s.board.center, in: s.doc)
    #expect(edits.contains { $0.id == s.module.id })
    #expect(contacts(in: applied(edits, to: s.doc)) == contacts(in: s.doc))
}

@Test func rotateObjectsResyncsAttachedWires() {
    let s = scene()
    let angle = Double.pi / 2, pivot = s.board.center
    let edits = rotateObjects([s.board.id, s.wireB.id], by: angle, around: pivot, in: s.doc)
    let after = applied(edits, to: s.doc)
    guard case .part(let m) = after.objects[1], case .wire(let a) = after.objects[2], case .wire(let b) = after.objects[3]
    else { Issue.record("shape"); return }
    let pins = connectorPositions(m, moduleDef)
    #expect(edits.contains { $0.id == s.wireA.id })
    #expect(near(a.start.position, pins["SCL"]!))
    #expect(a.end == s.wireA.end && a.bends == s.wireA.bends)
    #expect(near(b.start.position, pins["GND"]!))
    #expect(near(b.end.position, pivot + (s.wireB.end.position - pivot).rotated(by: angle)))
    #expect(near(b.bends[0], pivot + (s.wireB.bends[0] - pivot).rotated(by: angle)))
}

@Test func attachmentsUnchangedByRotation() {
    let s = scene()
    let after = applied(rotateObjects([s.board.id, s.wireB.id], by: 0.7, around: s.board.center, in: s.doc), to: s.doc)
    #expect(contacts(in: after) == contacts(in: s.doc))
    for (x, y) in zip(s.doc.objects, after.objects) {
        if case .wire(let w0) = x, case .wire(let w1) = y {
            #expect(w0.start.attachment == w1.start.attachment && w0.end.attachment == w1.end.attachment)
        }
    }
}

@Test func zeroAngleNoChanges() {
    let s = scene()
    #expect(rotateObjects([s.board.id, s.wireB.id], by: 0, around: .zero, in: s.doc).isEmpty)
}

// Jumper between a module pin and a board hole, bend in between; both ends ride the rotating board.
private func jumperScene() -> (Scene, Wire) {
    var s = scene()
    let pins = connectorPositions(s.module, moduleDef)
    let holes = connectorPositions(s.board, boardDef)
    let hole = holes["c3r3"] ?? holes.values.first!
    let key = holes.first { $0.value == hole }!.key
    let j = Wire(start: WireEnd(position: pins["GND"]!, attachment: .connector(part: s.module.id, connector: "GND")),
                 end: WireEnd(position: hole, attachment: .connector(part: s.board.id, connector: key)),
                 bends: [Vec2(x: 55, y: 25)])
    s.doc.objects.append(.wire(j))
    return (s, j)
}

@Test func rotateObjectsRotatesBendsOfWireBetweenRotatingParts() {
    let (s, j) = jumperScene()
    let angle = 0.6, pivot = s.board.center
    let edits = rotateObjects([s.board.id], by: angle, around: pivot, in: s.doc) // wire not in ids
    guard case .wire(let w)? = edits.first(where: { $0.id == j.id }),
          case .part(let m)? = edits.first(where: { $0.id == s.module.id }),
          case .part(let b)? = edits.first(where: { $0.id == s.board.id }) else { Issue.record("missing edits"); return }
    #expect(near(w.bends[0], pivot + (j.bends[0] - pivot).rotated(by: angle)))
    #expect(near(w.start.position, connectorPositions(m, moduleDef)["GND"]!))
    guard case .connector(_, let key) = j.end.attachment! else { return }
    #expect(near(w.end.position, connectorPositions(b, boardDef)[key]!))
}

@Test func rotateObjectsKeepsBendsOfOneEndAttachedWire() {
    let s = scene()
    let edits = rotateObjects([s.board.id], by: 0.6, around: s.board.center, in: s.doc)
    guard case .wire(let a)? = edits.first(where: { $0.id == s.wireA.id }) else { Issue.record("no wire edit"); return }
    #expect(a.bends == s.wireA.bends)
}

@Test func rotateObjectsWireInIdsWithBothEndsAttached() {
    let (s, j) = jumperScene()
    let angle = 0.6, pivot = s.board.center
    let edits = rotateObjects([s.board.id, j.id], by: angle, around: pivot, in: s.doc)
    guard case .wire(let w)? = edits.first(where: { $0.id == j.id }),
          case .part(let m)? = edits.first(where: { $0.id == s.module.id }),
          case .part(let b)? = edits.first(where: { $0.id == s.board.id }) else { Issue.record("missing edits"); return }
    #expect(near(w.bends[0], pivot + (j.bends[0] - pivot).rotated(by: angle)))
    #expect(near(w.start.position, connectorPositions(m, moduleDef)["GND"]!))
    guard case .connector(_, let key) = j.end.attachment! else { return }
    #expect(near(w.end.position, connectorPositions(b, boardDef)[key]!))
}
