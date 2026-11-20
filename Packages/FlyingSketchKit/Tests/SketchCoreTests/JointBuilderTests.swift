import Testing
@testable import SketchCore

private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

private func bar(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> SceneObject {
    .shape(ShapeObject(kind: .rectangle, start: v(x0, y0), end: v(x1, y1), fillColor: .black))
}

private func apply(_ edits: [SceneEdit], to doc: SketchDocument) -> SketchDocument {
    var d = doc
    for e in edits { _ = e.apply(to: &d) }
    return d
}

private func joints(_ d: SketchDocument) -> [Joint] {
    d.objects.compactMap { if case .joint(let j) = $0 { j } else { nil } }
}

@Test func pinJoinsAllBodiesUnderPoint() {
    let (a, b, c) = (bar(0, 0, 40, 40), bar(10, 10, 50, 50), bar(20, 20, 60, 60))
    let doc = SketchDocument(objects: [a, b, c])
    let edits = pinEdits(at: v(30, 30), under: [a.id, b.id, c.id], in: doc)
    let after = apply(edits, to: doc)
    let js = joints(after)
    #expect(js.count == 1)
    #expect(js[0].kind == .hinge && !js[0].grounded)
    #expect(js[0].position == v(30, 30))
    #expect(js[0].anchors.map(\.object) == [a.id, b.id, c.id])
    #expect(js[0].anchors.allSatisfy { $0.point == v(30, 30) })
    #expect(jointIntegrityEdits(in: after).isEmpty)
}

@Test func pinSingleObjectGrounds() {
    let a = bar(0, 0, 40, 40)
    let after = apply(pinEdits(at: v(5, 5), under: [a.id], in: SketchDocument(objects: [a])), to: SketchDocument(objects: [a]))
    let js = joints(after)
    #expect(js.count == 1 && js[0].grounded && js[0].anchors.count == 1)
    #expect(js[0].anchors[0] == JointAnchor(object: a.id, point: v(5, 5)))
}

@Test func pinNothingIsEmpty() {
    #expect(pinEdits(at: v(0, 0), under: [], in: SketchDocument(objects: [bar(0, 0, 4, 4)])).isEmpty)
}

@Test func pinSameBodyTwiceCountsOnce() {
    let (a, b) = (bar(0, 0, 40, 40), bar(10, 10, 50, 50))
    let doc = SketchDocument(objects: [a, b], groups: [ObjectGroup(members: [a.id, b.id])])
    let js = joints(apply(pinEdits(at: v(20, 20), under: [a.id, b.id], in: doc), to: doc))
    #expect(js.count == 1 && js[0].grounded && js[0].anchors.count == 1)
}

@Test func pinIgnoresWires() {
    let a = bar(0, 0, 40, 40)
    let w = SceneObject.wire(Wire(start: WireEnd(position: v(0, 20)), end: WireEnd(position: v(40, 20))))
    let doc = SketchDocument(objects: [a, w])
    let js = joints(apply(pinEdits(at: v(20, 20), under: [a.id, w.id], in: doc), to: doc))
    #expect(js.count == 1 && js[0].grounded && js[0].anchors.map(\.object) == [a.id])
    #expect(pinEdits(at: v(20, 20), under: [w.id], in: doc).isEmpty)
}

@Test func toggleGround() {
    let (a, b) = (bar(0, 0, 40, 40), bar(10, 10, 50, 50))
    let hinge = Joint(position: v(20, 20), anchors: [JointAnchor(object: a.id, point: v(20, 20)),
                                                     JointAnchor(object: b.id, point: v(20, 20))])
    var doc = SketchDocument(objects: [a, b, .joint(hinge)])
    doc = apply(toggleGroundEdits(joint: hinge.id, in: doc), to: doc)
    #expect(joints(doc)[0].grounded && joints(doc)[0].anchors.count == 2)
    doc = apply(toggleGroundEdits(joint: hinge.id, in: doc), to: doc)
    #expect(!joints(doc)[0].grounded && joints(doc)[0].anchors.count == 2)

    let pinned = Joint(position: v(5, 5), anchors: [JointAnchor(object: a.id, point: v(5, 5))], grounded: true)
    var single = SketchDocument(objects: [a, .joint(pinned)])
    single = apply(toggleGroundEdits(joint: pinned.id, in: single), to: single)
    #expect(joints(single).isEmpty)
    #expect(toggleGroundEdits(joint: a.id, in: single).isEmpty)
}

@Test func toggleLockAddsThenRemoves() {
    let (a, b) = (bar(0, 0, 40, 20), bar(60, 0, 100, 20))
    var doc = SketchDocument(objects: [a, b], groups: [ObjectGroup(members: [a.id, b.id])])
    doc = apply(toggleLockEdits(object: a.id, in: doc), to: doc)
    let js = joints(doc)
    #expect(js.count == 1 && js[0].kind == .fixed && js[0].grounded && js[0].anchors.count == 1)
    // Bounds of both bars (0.25 half line width): x -0.25...100.25, y -0.25...20.25.
    #expect(js[0].position == v(50, 10))
    #expect(js[0].anchors[0] == JointAnchor(object: a.id, point: v(50, 10)))
    #expect(jointIntegrityEdits(in: doc).isEmpty)
    doc = apply(toggleLockEdits(object: b.id, in: doc), to: doc) // any member removes it
    #expect(joints(doc).isEmpty)
}

@Test func groupMergesBodiesAndDropsInnerHinges() {
    let (a, b, c) = (bar(0, 0, 40, 10), bar(30, 0, 70, 10), bar(100, 0, 140, 10))
    let hinge = Joint(position: v(35, 5), anchors: [JointAnchor(object: a.id, point: v(35, 5)),
                                                    JointAnchor(object: b.id, point: v(35, 5))])
    let doc = SketchDocument(objects: [a, b, c, .joint(hinge)])
    let after = apply(groupEdits([a.id, b.id], in: doc), to: doc)
    #expect(after.groups.count == 1 && Set(after.groups[0].members) == [a.id, b.id])
    #expect(joints(after).isEmpty)
    #expect(jointIntegrityEdits(in: after).isEmpty)

    let grounded = Joint(position: v(35, 5), anchors: hinge.anchors, grounded: true)
    let gdoc = SketchDocument(objects: [a, b, c, .joint(grounded)])
    let gafter = apply(groupEdits([a.id, b.id], in: gdoc), to: gdoc)
    #expect(joints(gafter).count == 1 && joints(gafter)[0].grounded && joints(gafter)[0].anchors.count == 1)
    #expect(jointIntegrityEdits(in: gafter).isEmpty)
}

@Test func groupMergesExistingGroups() {
    let (a, b, c, d) = (bar(0, 0, 4, 4), bar(10, 0, 14, 4), bar(20, 0, 24, 4), bar(30, 0, 34, 4))
    let doc = SketchDocument(objects: [a, b, c, d], groups: [ObjectGroup(members: [a.id, b.id]),
                                                             ObjectGroup(members: [c.id, d.id])])
    let after = apply(groupEdits([b.id, c.id], in: doc), to: doc)
    #expect(after.groups.count == 1)
    #expect(Set(after.groups[0].members) == [a.id, b.id, c.id, d.id])
    // Selecting one group member alone merges nothing.
    #expect(groupEdits([a.id], in: doc).isEmpty)
}

@Test func groupNeedsTwoObjects() {
    let a = bar(0, 0, 4, 4)
    let w = SceneObject.wire(Wire(start: WireEnd(position: v(0, 0)), end: WireEnd(position: v(9, 9))))
    let doc = SketchDocument(objects: [a, w])
    #expect(groupEdits([a.id], in: doc).isEmpty)
    #expect(groupEdits([a.id, w.id], in: doc).isEmpty)
    #expect(groupEdits([], in: doc).isEmpty)
}

@Test func ungroupReattachesPins() {
    let a = bar(0, 0, 40, 10)
    let b = bar(50, 0, 90, 10)
    let c = bar(0, 30, 120, 40)
    let g = ObjectGroup(members: [a.id, b.id])
    let onB = Joint(position: v(70, 5), anchors: [JointAnchor(object: a.id, point: v(70, 5)),
                                                  JointAnchor(object: c.id, point: v(70, 5))])
    let nowhere = Joint(position: v(45, 5), anchors: [JointAnchor(object: a.id, point: v(45, 5)),
                                                      JointAnchor(object: c.id, point: v(45, 5))])
    let doc = SketchDocument(objects: [a, b, c, .joint(onB), .joint(nowhere)], groups: [g])
    let at: (Vec2) -> [ObjectID] = { p in [a, b].filter { hitTest($0, point: p, tolerance: 0.5) }.map(\.id) }
    let after = apply(ungroupEdits(group: g.id, objectsAt: at, in: doc), to: doc)
    #expect(after.groups.isEmpty)
    let js = joints(after)
    #expect(js.count == 1)
    #expect(js[0].id == onB.id)
    #expect(js[0].anchors.map(\.object) == [b.id, c.id])
    #expect(jointIntegrityEdits(in: after).isEmpty)
    #expect(ungroupEdits(group: ObjectID.new(), objectsAt: at, in: doc).isEmpty)
}

@Test func pinAtExistingHingeAddsNoDuplicate() {
    let (a, b, c) = (bar(0, 0, 40, 40), bar(10, 10, 50, 50), bar(20, 20, 60, 60))
    let hinge = Joint(position: v(30, 30), anchors: [JointAnchor(object: a.id, point: v(30, 30)),
                                                     JointAnchor(object: b.id, point: v(30, 30))])
    let doc = SketchDocument(objects: [a, b, c, .joint(hinge)])
    #expect(pinEdits(at: v(30, 30), under: [a.id, b.id], in: doc).isEmpty)
    let after = apply(pinEdits(at: v(30, 30), under: [a.id, b.id, c.id], in: doc), to: doc)
    #expect(joints(after).count == 1 && joints(after)[0].id == hinge.id)
    #expect(joints(after)[0].anchors.map(\.object) == [a.id, b.id, c.id])
    #expect(jointIntegrityEdits(in: after).isEmpty)
}

@Test func ungroupKeepsLocks() {
    let (a, b) = (bar(0, 0, 40, 10), bar(100, 0, 140, 10))
    let g = ObjectGroup(members: [a.id, b.id])
    var doc = SketchDocument(objects: [a, b], groups: [g])
    doc = apply(toggleLockEdits(object: b.id, in: doc), to: doc)
    let lock = joints(doc)[0]
    let after = apply(ungroupEdits(group: g.id, objectsAt: { _ in [] }, in: doc), to: doc)
    #expect(after.groups.isEmpty)
    #expect(joints(after) == [lock])
}

@Test func undoRestoresGroupAndGroundToggles() {
    let (a, b) = (bar(0, 0, 40, 10), bar(30, 0, 70, 10))
    let hinge = Joint(position: v(35, 5), anchors: [JointAnchor(object: a.id, point: v(35, 5)),
                                                    JointAnchor(object: b.id, point: v(35, 5))])
    let doc = SketchDocument(objects: [a, b, .joint(hinge)])
    for edits in [groupEdits([a.id, b.id], in: doc), toggleGroundEdits(joint: hinge.id, in: doc),
                  toggleLockEdits(object: a.id, in: doc)] {
        var d = doc
        var inverses: [SceneEdit] = []
        for e in edits { inverses.append(e.apply(to: &d)) }
        #expect(d != doc)
        for e in inverses.reversed() { _ = e.apply(to: &d) }
        #expect(d == doc)
    }
}
