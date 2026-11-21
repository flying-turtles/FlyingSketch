import Foundation
import Testing
import SketchCore
@testable import MechKit

// MARK: - Helpers

private func near(_ a: Vec2, _ b: Vec2, _ tol: Double) -> Bool { a.distance(to: b) <= tol }

private func object(_ id: ObjectID, in doc: SketchDocument) -> SceneObject? { doc.objects.first { $0.id == id } }

private func shape(_ id: ObjectID, in doc: SketchDocument) -> ShapeObject {
    guard case .shape(let s)? = object(id, in: doc) else { fatalError("no shape \(id)") }
    return s
}

private func joint(_ id: ObjectID, in doc: SketchDocument) -> Joint {
    guard case .joint(let j)? = object(id, in: doc) else { fatalError("no joint \(id)") }
    return j
}

private func length(_ s: ShapeObject) -> Double { s.start.distance(to: s.end) }

private func cross(_ u: Vec2, _ w: Vec2) -> Double { u.x * w.y - u.y * w.x }

/// Every joint's anchors coincide (grounded: on the unchanged `position`); `position` = first anchor otherwise.
private func expectPinsHold(_ doc: SketchDocument, start: SketchDocument, _ label: String = "") {
    for case .joint(let j) in doc.objects {
        let first = j.anchors[0].point
        for anchor in j.anchors { #expect(near(anchor.point, first, 1e-6), "\(label) anchors apart") }
        if j.grounded {
            #expect(j.position == joint(j.id, in: start).position, "\(label) ground moved")
            #expect(near(first, j.position, 1e-6), "\(label) off ground")
        } else {
            #expect(j.position == first, "\(label) position not first anchor")
        }
    }
}

private func expectBarLengths(_ doc: SketchDocument, _ fb: FourBar, _ label: String = "") {
    for id in fb.bars {
        #expect(abs(length(shape(id, in: doc)) - length(shape(id, in: fb.doc))) < 1e-9, "\(label) bar length")
    }
}

// MARK: - Mechanism

@Test func mechanismFindsConnectedBodies() {
    var fb = fourBarDocument()
    let unrelated = ShapeObject(kind: .rectangle, start: Vec2(x: 100, y: 100), end: Vec2(x: 110, y: 105))
    fb.doc.objects.append(.shape(unrelated))
    let m = Mechanism(containing: fb.coupler, in: fb.doc)
    #expect(m?.bodies == fb.bars)
    #expect(m.map { Set($0.joints) } == Set(fb.joints))
    #expect(m?.joints.count == 4)
    #expect(m?.objectIDs == Set(fb.bars))
    #expect(m?.hasGroundOrLock == true)
    #expect(Mechanism(containing: unrelated.id, in: fb.doc) == nil)
}

@Test func groupIsOneBody() {
    var fb = fourBarDocument()
    let label = TextObject(text: "coupler", position: (fb.b + fb.c) / 2 + Vec2(x: 0, y: -3))
    fb.doc.objects.append(.text(label))
    let group = ObjectGroup(members: [fb.coupler, label.id])
    fb.doc.groups = [group]
    let m = Mechanism(containing: label.id, in: fb.doc)
    #expect(m?.bodies == [fb.crank, group.id, fb.rocker])
    #expect(m?.members(of: group.id) == [fb.coupler, label.id])
    #expect(m?.objectIDs.contains(label.id) == true)

    guard let drag = MechanismDrag(grabbing: fb.crank, at: fb.b, in: fb.doc) else { Issue.record("no drag"); return }
    let after = applied(drag.move(to: crankTip(-60)), to: fb.doc)
    let bar0 = shape(fb.coupler, in: fb.doc), bar1 = shape(fb.coupler, in: after)
    guard case .text(let moved)? = object(label.id, in: after) else { Issue.record("no label"); return }
    #expect(moved != label)
    #expect(abs(moved.position.distance(to: bar1.start) - label.position.distance(to: bar0.start)) < 1e-9)
    #expect(abs(moved.position.distance(to: bar1.end) - label.position.distance(to: bar0.end)) < 1e-9)
    let turn = atan2(cross(bar0.end - bar0.start, bar1.end - bar1.start),
                     (bar0.end - bar0.start).x * (bar1.end - bar1.start).x + (bar0.end - bar0.start).y * (bar1.end - bar1.start).y)
    #expect(abs(remainder(moved.rotation - turn, 2 * .pi)) < 1e-9)
}

// MARK: - Drag

@Test func dragMovesBarsAndKeepsPins() {
    let fb = fourBarDocument()
    guard let drag = MechanismDrag(grabbing: fb.crank, at: fb.b, in: fb.doc) else { Issue.record("no drag"); return }
    let result = drag.move(to: crankTip(-60))
    #expect(result == drag.replacements)
    let shapes = result.filter { if case .shape = $0 { true } else { false } }
    let joints = result.filter { if case .joint = $0 { true } else { false } }
    #expect(Set(shapes.map(\.id)) == Set(fb.bars))
    #expect(Set(joints.map(\.id)) == Set(fb.joints))
    #expect(result.count == 7)
    let after = applied(result, to: fb.doc)
    expectPinsHold(after, start: fb.doc)
    expectBarLengths(after, fb)
    #expect(near(shape(fb.crank, in: after).end, crankTip(-60), 1e-3))
}

@Test func noAccumulationOverManyFrames() {
    let fb = fourBarDocument()
    guard let drag = MechanismDrag(grabbing: fb.crank, at: fb.b, in: fb.doc) else { Issue.record("no drag"); return }
    for frame in 1...500 {
        // Five sweeps -90° -> 0° -> -90°, ending on the start.
        let degrees = -90 + 45 * (1 - cos(2 * .pi * 5 * Double(frame) / 500))
        let after = applied(drag.move(to: crankTip(degrees)), to: fb.doc)
        expectBarLengths(after, fb, "frame \(frame)")
        if frame % 50 == 0 { expectPinsHold(after, start: fb.doc, "frame \(frame)") }
    }
    let end = applied(drag.replacements, to: fb.doc)
    for id in fb.bars {
        let s0 = shape(id, in: fb.doc), s1 = shape(id, in: end)
        #expect(near(s0.start, s1.start, 1e-4) && near(s0.end, s1.end, 1e-4))
    }
}

@Test func doesNotFlipAssembly() {
    let fb = fourBarDocument()
    guard let drag = MechanismDrag(grabbing: fb.crank, at: fb.b, in: fb.doc) else { Issue.record("no drag"); return }
    let startSign = cross(fb.c - fb.b, fb.d - fb.b).sign
    // A full crank turn (the linkage is a Grashof crank-rocker) and back.
    for degrees in Array(stride(from: -87.0, through: 270, by: 3)) + Array(stride(from: 267.0, through: -90, by: -3)) {
        let after = applied(drag.move(to: crankTip(degrees)), to: fb.doc)
        let b = shape(fb.crank, in: after).end, c = shape(fb.coupler, in: after).end
        #expect(near(b, crankTip(degrees), 1e-3), "\(degrees)°: B \(b)")
        #expect(cross(c - b, fb.d - b).sign == startSign, "\(degrees)°: mirror flip")
        expectPinsHold(after, start: fb.doc, "\(degrees)°")
    }
}

@Test func lockedBodyStays() {
    var fb = fourBarDocument()
    let mid = (fb.b + fb.c) / 2
    fb.doc.objects.append(.joint(Joint(kind: .fixed, position: mid, anchors: [JointAnchor(object: fb.coupler, point: mid)],
                                       grounded: true)))
    guard let drag = MechanismDrag(grabbing: fb.crank, at: fb.b, in: fb.doc) else { Issue.record("no drag"); return }
    for degrees in [-80.0, -60, -30] {
        let result = drag.move(to: crankTip(degrees))
        #expect(!result.contains { if case .shape = $0 { true } else { false } }, "\(degrees)°")
    }
}

@Test func carriedPartsRide() {
    let boardDef = PartDefinition.fixtureBreadboardMini(), moduleDef = PartDefinition.fixtureModule()
    let board = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 40, y: 0))
    var module = PartInstance(definitionKey: moduleDef.key, center: Vec2(x: 40, y: 0))
    let holes = connectorPositions(board, boardDef)
    module.center = module.center + (holes["c0r1"]! - connectorPositions(module, moduleDef)["VCC"]!)
    let pins = connectorPositions(module, moduleDef)
    let wire = Wire(start: WireEnd(position: pins["SCL"]!, attachment: .connector(part: module.id, connector: "SCL")),
                    end: WireEnd(position: Vec2(x: 70, y: 20)), bends: [Vec2(x: 60, y: 10)])
    // Jumper with both ends on the body: its bend rides rigidly.
    let jumper = Wire(start: WireEnd(position: pins["GND"]!, attachment: .connector(part: module.id, connector: "GND")),
                      end: WireEnd(position: holes["c3r4"]!, attachment: .connector(part: board.id, connector: "c3r4")),
                      bends: [Vec2(x: 46, y: 9)])
    let pivot = board.center + Vec2(x: -6, y: -7)
    let pin = Joint(position: pivot, anchors: [JointAnchor(object: board.id, point: pivot)], grounded: true)
    let doc = SketchDocument(objects: [.part(board), .part(module), .wire(wire), .wire(jumper), .joint(pin)],
                             parts: [boardDef.key: boardDef, moduleDef.key: moduleDef])
    #expect(!contacts(in: doc).isEmpty)
    #expect(Mechanism(containing: board.id, in: doc)?.members(of: board.id) == [board.id, module.id])

    let grab = board.center + Vec2(x: 6, y: 7)
    guard let drag = MechanismDrag(grabbing: board.id, at: grab, in: doc) else { Issue.record("no drag"); return }
    var after = doc
    for frame in 1...10 {
        after = applied(drag.move(to: grab + Vec2(x: -1.5, y: 1) * Double(frame)), to: doc)
    }
    guard case .part(let b1)? = object(board.id, in: after), case .part(let m1)? = object(module.id, in: after),
          case .wire(let w1)? = object(wire.id, in: after), case .wire(let j1)? = object(jumper.id, in: after)
    else { Issue.record("missing objects"); return }
    #expect(abs(b1.rotation) > 0.3)
    #expect(m1 != module)
    #expect(near(joint(pin.id, in: after).anchors[0].point, pivot, 1e-6))
    #expect(contacts(in: after) == contacts(in: doc))
    #expect(w1.start.attachment == wire.start.attachment && w1.end.attachment == wire.end.attachment)
    #expect(near(w1.start.position, connectorPositions(m1, moduleDef)["SCL"]!, 1e-12))
    #expect(w1.end == wire.end && w1.bends == wire.bends)
    #expect(j1.start.attachment == jumper.start.attachment && j1.end.attachment == jumper.end.attachment)
    #expect(near(j1.end.position, connectorPositions(b1, boardDef)["c3r4"]!, 1e-12))
    let bend = board.center + (jumper.bends[0] - board.center).rotated(by: b1.rotation) + (b1.center - board.center)
    #expect(near(j1.bends[0], bend, 1e-9))
}

/// Board grounded at a pivot with a module plugged in at c0r1; `extra` objects are appended.
private func pivotBoard(_ extra: [SceneObject] = [], groups: [ObjectGroup] = [],
                        module moduleAt: String = "c0r1")
    -> (doc: SketchDocument, board: PartInstance, module: PartInstance, pin: Joint, pivot: Vec2) {
    let boardDef = PartDefinition.fixtureBreadboardMini(), moduleDef = PartDefinition.fixtureModule()
    let board = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 40, y: 0))
    var module = PartInstance(definitionKey: moduleDef.key, center: Vec2(x: 40, y: 0))
    module.center = module.center
        + (connectorPositions(board, boardDef)[moduleAt]! - connectorPositions(module, moduleDef)["VCC"]!)
    let pivot = board.center + Vec2(x: -6, y: -7)
    let pin = Joint(position: pivot, anchors: [JointAnchor(object: board.id, point: pivot)], grounded: true)
    let doc = SketchDocument(objects: [.part(board), .part(module), .joint(pin)] + extra,
                             parts: [boardDef.key: boardDef, moduleDef.key: moduleDef], groups: groups)
    return (doc, board, module, pin, pivot)
}

/// Drags the pivot board's far corner around the pivot by `angle`; the applied result.
private func turnBoard(_ doc: SketchDocument, _ board: PartInstance, pivot: Vec2, by angle: Double) -> SketchDocument? {
    let grab = board.center + Vec2(x: 6, y: 7)
    guard let drag = MechanismDrag(grabbing: board.id, at: grab, in: doc) else { return nil }
    var result: [SceneObject] = []
    for k in 1...10 { result = drag.move(to: pivot + (grab - pivot).rotated(by: angle * Double(k) / 10)) }
    return applied(result, to: doc)
}

/// A module plugged into the dragged board rides along with its whole group (label included).
@Test func groupedPluggedModuleRidesWithItsGroup() throws {
    let label = TextObject(text: "U1", position: Vec2(x: 60, y: 20))
    var setup = pivotBoard([.text(label)])
    let group = ObjectGroup(members: [setup.module.id, label.id])
    setup.doc.groups = [group]
    let m = try #require(Mechanism(containing: setup.board.id, in: setup.doc))
    #expect(m.members(of: setup.board.id) == [setup.board.id, setup.module.id, label.id])
    let after = try #require(turnBoard(setup.doc, setup.board, pivot: setup.pivot, by: 0.5))
    guard case .part(let b1)? = object(setup.board.id, in: after), case .part(let m1)? = object(setup.module.id, in: after),
          case .text(let t1)? = object(label.id, in: after) else { Issue.record("missing"); return }
    let motion = { (p: Vec2) in setup.pivot + (p - setup.pivot).rotated(by: b1.rotation) }
    #expect(abs(b1.rotation - 0.5) < 1e-3)
    #expect(near(m1.center, motion(setup.module.center), 1e-9))
    #expect(near(t1.position, motion(label.position), 1e-9))
    #expect(contacts(in: after) == contacts(in: setup.doc))
}

/// A carried group with a pinned member holds by its pin: neither the plugged module nor its group-mate moves.
@Test func anchoredGroupOfPluggedModuleIsNotCarried() throws {
    let label = TextObject(text: "U1", position: Vec2(x: 60, y: 20))
    let hold = Joint(position: label.position, anchors: [JointAnchor(object: label.id, point: label.position)],
                     grounded: true)
    var setup = pivotBoard([.text(label), .joint(hold)])
    setup.doc.groups = [ObjectGroup(members: [setup.module.id, label.id])]
    let m = try #require(Mechanism(containing: setup.board.id, in: setup.doc))
    #expect(m.members(of: setup.board.id) == [setup.board.id])
    let after = try #require(turnBoard(setup.doc, setup.board, pivot: setup.pivot, by: 0.5))
    #expect(object(setup.module.id, in: after) == .part(setup.module))
    #expect(object(label.id, in: after) == .text(label))
}

@Test func failedSolveKeepsPreviousResult() {
    // Two locked bars whose shared hinge anchors are 50 mm apart, plus a free bar hinged to one of them.
    let p = Vec2(x: 0, y: 0), q = Vec2(x: 60, y: 0), r = Vec2(x: 60, y: 20)
    let l1 = ShapeObject(kind: .line, start: Vec2(x: -10, y: 0), end: p)
    let l2 = ShapeObject(kind: .line, start: Vec2(x: 50, y: 0), end: q)
    let l3 = ShapeObject(kind: .line, start: q, end: r)
    let lock1 = Joint(kind: .fixed, position: l1.start, anchors: [JointAnchor(object: l1.id, point: l1.start)], grounded: true)
    let lock2 = Joint(kind: .fixed, position: q, anchors: [JointAnchor(object: l2.id, point: q)], grounded: true)
    let broken = Joint(position: p, anchors: [JointAnchor(object: l1.id, point: p), JointAnchor(object: l2.id, point: l2.start)])
    let hinge = Joint(position: q, anchors: [JointAnchor(object: l2.id, point: q), JointAnchor(object: l3.id, point: q)])
    let doc = SketchDocument(objects: [.shape(l1), .shape(l2), .shape(l3),
                                       .joint(lock1), .joint(lock2), .joint(broken), .joint(hinge)])
    guard let drag = MechanismDrag(grabbing: l3.id, at: r, in: doc) else { Issue.record("no drag"); return }
    for target in [Vec2(x: 70, y: 15), Vec2(x: 75, y: 5)] {
        #expect(drag.move(to: target) == [])
        #expect(drag.replacements == [])
    }
}

// MARK: - Selections

@Test func selectionCoverageAndPinning() {
    var fb = fourBarDocument()
    let loose = ShapeObject(kind: .ellipse, start: Vec2(x: 100, y: 0), end: Vec2(x: 110, y: 10))
    fb.doc.objects.append(.shape(loose))
    let whole = Set(fb.bars + fb.joints)
    #expect(selectionCoversWholeMechanisms(whole, in: fb.doc))
    #expect(!selectionIsPinnedToOutside(whole, in: fb.doc))
    #expect(!selectionCoversWholeMechanisms(Set(fb.bars), in: fb.doc))
    #expect(selectionIsPinnedToOutside(Set(fb.bars), in: fb.doc))
    #expect(selectionCoversWholeMechanisms([loose.id], in: fb.doc))
    #expect(!selectionIsPinnedToOutside([loose.id], in: fb.doc))
    // One bar: its hinges also hold bars outside the selection.
    #expect(!selectionCoversWholeMechanisms([fb.coupler], in: fb.doc))
    #expect(selectionIsPinnedToOutside([fb.coupler], in: fb.doc))
    // Pins without their bars: rotating would move the pins off them.
    #expect(selectionIsPinnedToOutside(Set(fb.joints), in: fb.doc))
    #expect(selectionIsPinnedToOutside([fb.jointB, fb.jointC], in: fb.doc))
    #expect(selectionIsPinnedToOutside([fb.jointA], in: fb.doc))
    #expect(!selectionIsPinnedToOutside(whole.union([loose.id]), in: fb.doc))
}

@Test func ungroundedPlateStaysInDocumentDrag() {
    // Filled plate with a bar hinged at its right edge; no ground, no lock.
    let pin = Vec2(x: 0, y: 0), tip = Vec2(x: 30, y: 0)
    let plate = ShapeObject(kind: .rectangle, start: Vec2(x: -20, y: -10), end: Vec2(x: 0, y: 10), fillColor: .black)
    let bar = ShapeObject(kind: .line, start: pin, end: tip)
    let hinge = Joint(position: pin, anchors: [JointAnchor(object: plate.id, point: pin), JointAnchor(object: bar.id, point: pin)])
    let doc = SketchDocument(objects: [.shape(plate), .shape(bar), .joint(hinge)])
    guard let drag = MechanismDrag(grabbing: bar.id, at: tip, in: doc) else { Issue.record("no drag"); return }
    var result: [SceneObject] = []
    for step in 1...9 {
        let a = Double(step) * 5 * .pi / 180
        result = drag.move(to: Vec2(x: 30 * cos(a), y: 30 * sin(a)))
    }
    let after = applied(result, to: doc)
    let moved = shape(plate.id, in: after)
    print("ungroundedPlateStaysInDocumentDrag: plate moved \(moved.start.distance(to: plate.start)) mm")
    #expect(near(moved.start, plate.start, 1e-3) && near(moved.end, plate.end, 1e-3), "\(moved)")
    #expect(abs(moved.rotation - plate.rotation) < 1e-4)
    #expect(near(shape(bar.id, in: after).end, Vec2(x: 30 * cos(Double.pi / 4), y: 30 * sin(Double.pi / 4)), 1e-3))
}

/// Ungrounded chain of `n` 10 mm `.line` bars along +x, hinged end to end.
private func barChain(_ n: Int) -> (doc: SketchDocument, first: ObjectID) {
    let bars = (0..<n).map { i in
        ShapeObject(kind: .line, start: Vec2(x: Double(i) * 10, y: 0), end: Vec2(x: Double(i + 1) * 10, y: 0))
    }
    let hinges = (1..<n).map { i in
        let p = Vec2(x: Double(i) * 10, y: 0)
        return Joint(position: p, anchors: [JointAnchor(object: bars[i - 1].id, point: p), JointAnchor(object: bars[i].id, point: p)])
    }
    return (SketchDocument(objects: bars.map { .shape($0) } + hinges.map { .joint($0) }), bars[0].id)
}

@Test func hugeMechanismHasNoDrag() {
    let big = barChain(501)
    #expect(MechanismDrag(grabbing: big.first, at: Vec2(x: 0, y: 0), in: big.doc) == nil)
    let small = barChain(50)
    #expect(MechanismDrag(grabbing: small.first, at: Vec2(x: 0, y: 0), in: small.doc) != nil)
}
