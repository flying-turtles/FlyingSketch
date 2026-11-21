import Testing
@testable import SketchCore

private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

private func bar(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> SceneObject {
    .shape(ShapeObject(kind: .rectangle, start: v(x0, y0), end: v(x1, y1), fillColor: .black))
}

private func joints(_ d: SketchDocument) -> [Joint] {
    d.objects.compactMap { if case .joint(let j) = $0 { j } else { nil } }
}

/// Applies `edits` in order and the inverses in reverse order; returns (after, restored).
private func roundTrip(_ edits: [SceneEdit], on doc: SketchDocument) -> (after: SketchDocument, restored: SketchDocument) {
    var d = doc
    let inverses = edits.map { $0.apply(to: &d) }
    let after = d
    for inverse in inverses.reversed() { _ = inverse.apply(to: &d) }
    return (after, d)
}

@Test func unlockUndoRestoresDocument() {
    let a = bar(0, 0, 40, 40), other = bar(60, 0, 80, 40)
    let lock = Joint(kind: .fixed, position: v(20, 20), anchors: [JointAnchor(object: a.id, point: v(20, 20))], grounded: true)
    let doc = SketchDocument(objects: [a, .joint(lock), other])
    let edits = toggleLockEdits(object: a.id, in: doc)
    #expect(!edits.isEmpty)
    let (after, restored) = roundTrip(edits, on: doc)
    #expect(joints(after).isEmpty)
    #expect(restored == doc)
    #expect(joints(restored).first == lock)
}

@Test func ungroundUndoRestoresDocument() {
    let (a, b) = (bar(0, 0, 40, 40), bar(10, 10, 50, 50))
    let h = Joint(kind: .hinge, position: v(30, 30),
                  anchors: [JointAnchor(object: a.id, point: v(30, 30)), JointAnchor(object: b.id, point: v(30, 30))],
                  grounded: true)
    let doc = SketchDocument(objects: [a, .joint(h), b])
    let (after, restored) = roundTrip(toggleGroundEdits(joint: h.id, in: doc), on: doc)
    #expect(joints(after).count == 1 && !joints(after)[0].grounded)
    #expect(restored == doc)
    // grounding again, then undoing, restores the ungrounded state
    let (regrounded, back) = roundTrip(toggleGroundEdits(joint: h.id, in: after), on: after)
    #expect(joints(regrounded)[0].grounded)
    #expect(back == after)
}

@Test func ungroundSinglePinRemovesJointAndUndoRestores() {
    let a = bar(0, 0, 40, 40)
    let pin = Joint(kind: .hinge, position: v(5, 5), anchors: [JointAnchor(object: a.id, point: v(5, 5))], grounded: true)
    let doc = SketchDocument(objects: [a, .joint(pin)])
    let (after, restored) = roundTrip(toggleGroundEdits(joint: pin.id, in: doc), on: doc)
    #expect(joints(after).isEmpty)
    #expect(restored == doc)
}

@Test func groupMergingExistingGroupUndoRestoresDocument() {
    let (a, b, c) = (bar(0, 0, 10, 10), bar(20, 0, 30, 10), bar(40, 0, 50, 10))
    let existing = ObjectGroup(members: [a.id, b.id])
    let h = Joint(kind: .hinge, position: v(5, 5), anchors: [JointAnchor(object: a.id, point: v(5, 5))], grounded: true)
    let doc = SketchDocument(objects: [a, b, c, .joint(h)], groups: [existing])
    let edits = groupEdits([a.id, c.id], in: doc)
    #expect(!edits.isEmpty)
    let (after, restored) = roundTrip(edits, on: doc)
    #expect(after.groups.count == 1 && Set(after.groups[0].members) == [a.id, b.id, c.id])
    #expect(!after.groups.contains(existing))
    #expect(jointIntegrityEdits(in: after).isEmpty)
    #expect(restored == doc)
    #expect(restored.groups == [existing])
}
