import Foundation
import Testing
@testable import SketchCore

private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

private func bar(_ x: Double = 0) -> SceneObject {
    .shape(ShapeObject(kind: .line, start: v(x, 0), end: v(x + 10, 0), lineWidth: 1))
}

private func hinge(_ pos: Vec2, on objects: [ObjectID], grounded: Bool = false) -> Joint {
    Joint(kind: .hinge, position: pos, anchors: objects.map { JointAnchor(object: $0, point: pos) }, grounded: grounded)
}

private func wrapper(_ json: String) -> FileWrapper {
    FileWrapper(directoryWithFileWrappers: ["document.json": FileWrapper(regularFileWithContents: Data(json.utf8))])
}

private func writtenJSON(_ doc: SketchDocument) throws -> String {
    let w = try DocumentPackage.fileWrapper(for: doc)
    return String(decoding: try #require(w.fileWrappers?["document.json"]?.regularFileContents), as: UTF8.self)
}

private func expectCorrupt(_ json: String) {
    do {
        _ = try DocumentPackage.read(wrapper(json))
        Issue.record("expected throw")
    } catch let e as DocumentError {
        guard case .corrupt = e else { Issue.record("expected .corrupt, got \(e)"); return }
    } catch { Issue.record("unexpected \(error)") }
}

private func jointCount(_ doc: SketchDocument) -> Int {
    doc.objects.filter { if case .joint = $0 { true } else { false } }.count
}

/// Applies the integrity edits and returns the result.
private func repaired(_ doc: SketchDocument) -> SketchDocument {
    var d = doc
    for e in jointIntegrityEdits(in: doc) { _ = e.apply(to: &d) }
    return d
}

@Test func jointRoundTripsThroughPackage() throws {
    let (a, b, c, d) = (bar(0), bar(20), bar(40), bar(60))
    let two = hinge(v(5, 0), on: [a.id, b.id])
    let ground = hinge(v(1, 0), on: [a.id], grounded: true)
    let lock = Joint(kind: .fixed, position: v(22, 0), anchors: [JointAnchor(object: b.id, point: v(22, 0))],
                     grounded: true)
    let group = ObjectGroup(members: [c.id, d.id])
    var doc = SketchDocument(objects: [a, b, c, d, .joint(two), .joint(ground), .joint(lock)], groups: [group])
    #expect(try writtenJSON(doc).contains("\"formatVersion\":4"))
    let back = try DocumentPackage.read(try DocumentPackage.fileWrapper(for: doc))
    doc.formatVersion = 4
    #expect(back == doc)
}

@Test func olderVersionsOpen() throws {
    let json = try writtenJSON(SketchDocument(objects: [bar()]))
        .replacingOccurrences(of: "\"formatVersion\":4", with: "\"formatVersion\":3")
        .replacingOccurrences(of: ",\"groups\":[]", with: "")
    #expect(!json.contains("groups"))
    let doc = try DocumentPackage.read(wrapper(json))
    #expect(doc.groups == [])
    #expect(doc.formatVersion == 4)
    #expect(doc.objects.count == 1)
}

@Test func version5Rejected() throws {
    let json = try writtenJSON(SketchDocument())
        .replacingOccurrences(of: "\"formatVersion\":4", with: "\"formatVersion\":5")
    do {
        _ = try DocumentPackage.read(wrapper(json))
        Issue.record("expected throw")
    } catch let e as DocumentError {
        #expect(e == .unsupportedVersion(5))
    }
}

@Test func jointTranslatesAndRotatesWithAnchors() {
    let id = ObjectID.new()
    let j = SceneObject.joint(Joint(position: v(10, 0), anchors: [JointAnchor(object: id, point: v(10, 0)),
                                                                   JointAnchor(object: .new(), point: v(10, 0))]))
    guard case .joint(let moved) = j.translated(by: v(3, 4)) else { Issue.record("not a joint"); return }
    #expect(moved.position == v(13, 4))
    #expect(moved.anchors.allSatisfy { $0.point == v(13, 4) })
    guard case .joint(let spun) = j.rotated(by: .pi / 2, around: .zero) else { Issue.record("not a joint"); return }
    #expect(spun.position.distance(to: v(0, 10)) < 1e-9)
    #expect(spun.anchors.allSatisfy { $0.point.distance(to: v(0, 10)) < 1e-9 })
}

@Test func jointBoundsAndHit() {
    let j = SceneObject.joint(Joint(position: v(5, 5)))
    let b = bounds(of: j)
    #expect(abs(b.minX - 3.8) < 1e-9 && abs(b.minY - 3.8) < 1e-9)
    #expect(abs(b.size.x - 2.4) < 1e-9 && abs(b.size.y - 2.4) < 1e-9)
    #expect(hitTest(j, point: v(5.9, 5), tolerance: 0))
    #expect(!hitTest(j, point: v(7, 5), tolerance: 0))
    #expect(lassoContains([v(0, 0), v(10, 0), v(10, 10), v(0, 10)], object: j))
    #expect(!lassoContains([v(0, 0), v(4, 0), v(4, 4), v(0, 4)], object: j))
}

@Test func bodyIDUsesGroup() {
    let (a, b, c) = (bar(0), bar(20), bar(40))
    let g = ObjectGroup(members: [a.id, b.id])
    let doc = SketchDocument(objects: [a, b, c], groups: [g])
    #expect(bodyID(of: a.id, in: doc) == g.id)
    #expect(bodyID(of: b.id, in: doc) == g.id)
    #expect(bodyID(of: c.id, in: doc) == c.id)
    #expect(bodyMembers(g.id, in: doc) == [a.id, b.id])
    #expect(bodyMembers(c.id, in: doc) == [c.id])
}

@MainActor
@Test func setGroupsIsUndoable() {
    let g = ObjectGroup(members: [.new(), .new()])
    let um = UndoManager()
    um.groupsByEvent = false
    let model = DocumentModel(document: SketchDocument(), undoManager: um)
    var changes = 0
    model.onChange = { _ in changes += 1 }
    um.beginUndoGrouping()
    model.perform(.setGroups([g]), actionName: "Group")
    um.endUndoGrouping()
    #expect(model.document.groups == [g])
    #expect(changes == 1)
    #expect(um.canUndo)
    um.undo()
    #expect(model.document.groups == [])
    #expect(!um.canUndo && um.canRedo)
    um.redo()
    #expect(model.document.groups == [g])
}

@Test func integrityDropsAnchorsOfMissingObjects() {
    let (a, b, c) = (bar(0), bar(20), bar(40))
    let missing = ObjectID.new()
    // Hinge A-B, B absent: one anchor, not grounded -> removed.
    let h1 = hinge(v(5, 0), on: [a.id, missing])
    // Grounded hinge A-B, B absent: kept with one anchor.
    let h2 = hinge(v(6, 0), on: [a.id, missing], grounded: true)
    // Hinge A-B-C, C absent: kept with A, B.
    let h3 = hinge(v(7, 0), on: [a.id, b.id, missing])
    let doc = SketchDocument(objects: [a, b, c, .joint(h1), .joint(h2), .joint(h3)])
    let fixed = repaired(doc)
    let joints = fixed.objects.compactMap { o -> Joint? in if case .joint(let j) = o { j } else { nil } }
    #expect(joints.map(\.id) == [h2.id, h3.id])
    #expect(joints[0].anchors.map(\.object) == [a.id])
    #expect(joints[1].anchors.map(\.object) == [a.id, b.id])
    #expect(jointIntegrityEdits(in: fixed).isEmpty)
}

@Test func integrityIgnoresWireAnchors() {
    let a = bar(0)
    let w = Wire(start: WireEnd(position: v(0, 5)), end: WireEnd(position: v(5, 5)))
    let doc = SketchDocument(objects: [a, .wire(w), .joint(hinge(v(1, 1), on: [a.id, w.id]))])
    #expect(jointCount(repaired(doc)) == 0)
}

@Test func integrityCollapsesSameBodyAnchors() {
    let (a, b) = (bar(0), bar(20))
    let g = ObjectGroup(members: [a.id, b.id])
    let h = hinge(v(5, 0), on: [a.id, b.id])
    let doc = SketchDocument(objects: [a, b, .joint(h)], groups: [g])
    #expect(jointCount(repaired(doc)) == 0)
    // Grounded: kept with the first anchor only.
    let grounded = SketchDocument(objects: [a, b, .joint(hinge(v(5, 0), on: [a.id, b.id], grounded: true))], groups: [g])
    let fixed = repaired(grounded)
    guard case .joint(let j)? = fixed.objects.last else { Issue.record("joint lost"); return }
    #expect(j.anchors.map(\.object) == [a.id])
}

@Test func integrityCleansGroups() {
    let (a, b, c, d) = (bar(0), bar(20), bar(40), bar(60))
    let w = Wire(start: WireEnd(position: v(0, 5)), end: WireEnd(position: v(5, 5)))
    let missing = ObjectID.new()
    let g1 = ObjectGroup(members: [a.id, b.id, missing])
    let g2 = ObjectGroup(members: [c.id, missing])
    let g3 = ObjectGroup(members: [c.id, d.id, w.id])
    let fixed = repaired(SketchDocument(objects: [a, b, c, d, .wire(w)], groups: [g1, g2, g3]))
    #expect(fixed.groups.map(\.id) == [g1.id, g3.id])
    #expect(fixed.groups[0].members == [a.id, b.id])
    #expect(fixed.groups[1].members == [c.id, d.id])
}

@MainActor
@Test func deletionRemovesPinsInOneUndo() {
    let (a, b) = (bar(0), bar(20))
    let doc = SketchDocument(objects: [a, b, .joint(hinge(v(5, 0), on: [a.id, b.id]))])
    let um = UndoManager()
    um.groupsByEvent = false
    let model = DocumentModel(document: doc, undoManager: um)
    um.beginUndoGrouping()
    model.perform(deletionEdits([b.id], in: doc), actionName: "Delete")
    um.endUndoGrouping()
    #expect(model.document.objects.map(\.id) == [a.id])
    um.undo()
    #expect(model.document == doc)
}

@Test func corruptJointRejected() throws {
    let (a, b) = (bar(0), bar(20))
    let bad = Joint(kind: .fixed, position: v(5, 0),
                    anchors: [JointAnchor(object: a.id, point: v(5, 0)), JointAnchor(object: b.id, point: v(5, 0))],
                    grounded: true)
    expectCorrupt(try writtenJSON(SketchDocument(objects: [a, b, .joint(bad)])))
    let notGrounded = Joint(kind: .fixed, position: v(5, 0), anchors: [JointAnchor(object: a.id, point: v(5, 0))])
    expectCorrupt(try writtenJSON(SketchDocument(objects: [a, .joint(notGrounded)])))
    let empty = Joint(kind: .hinge, position: v(5, 0))
    expectCorrupt(try writtenJSON(SketchDocument(objects: [a, .joint(empty)])))

    let ok = hinge(v(777.25, 0), on: [a.id], grounded: true)
    var json = try writtenJSON(SketchDocument(objects: [a, .joint(ok)]))
    let range = try #require(json.range(of: "\"position\":{\"x\":777.25"))
    json.replaceSubrange(range, with: "\"position\":{\"x\":1e999")
    expectCorrupt(json)
}

@Test func fileRepairOnRead() throws {
    let a = bar(0)
    let ghost = ObjectID.new()
    let dropped = hinge(v(5, 0), on: [a.id, ghost])
    let kept = hinge(v(6, 0), on: [a.id, ghost], grounded: true)
    let doc = SketchDocument(objects: [a, .joint(dropped), .joint(kept)])
    let back = try DocumentPackage.read(try DocumentPackage.fileWrapper(for: doc))
    #expect(back.objects.map(\.id) == [a.id, kept.id])
    guard case .joint(let j) = back.objects[1] else { Issue.record("joint lost"); return }
    #expect(j.anchors.map(\.object) == [a.id])
}

@Test func integrityDropsJointAnchors() {
    let a = bar(0)
    let j1 = hinge(v(1, 0), on: [a.id])
    let j2 = hinge(v(2, 0), on: [a.id, j1.id])
    let selfPinned = Joint(position: v(3, 0))
    var s = selfPinned
    s.anchors = [JointAnchor(object: a.id, point: v(3, 0)), JointAnchor(object: s.id, point: v(3, 0))]
    let doc = SketchDocument(objects: [a, .joint(j1), .joint(j2), .joint(s)])
    let fixed = repaired(doc)
    #expect(jointCount(fixed) == 0)
    #expect(jointIntegrityEdits(in: fixed).isEmpty)
}

@Test func integrityDropsJointsFromGroups() {
    let (a, b) = (bar(0), bar(20))
    let j = hinge(v(1, 0), on: [a.id], grounded: true)
    let g1 = ObjectGroup(members: [a.id, j.id])
    let g2 = ObjectGroup(members: [a.id, b.id, j.id])
    let fixed = repaired(SketchDocument(objects: [a, b, .joint(j)], groups: [g1, g2]))
    #expect(fixed.groups == [ObjectGroup(id: g2.id, members: [a.id, b.id])])
    #expect(jointIntegrityEdits(in: fixed).isEmpty)
}

@Test func integrityDedupesGroupMembers() {
    let (a, b) = (bar(0), bar(20))
    let g1 = ObjectGroup(members: [a.id, a.id])
    let g2 = ObjectGroup(members: [a.id, a.id, b.id])
    let fixed = repaired(SketchDocument(objects: [a, b], groups: [g1, g2]))
    #expect(fixed.groups == [ObjectGroup(id: g2.id, members: [a.id, b.id])])
    #expect(jointIntegrityEdits(in: fixed).isEmpty)
}

@Test func integrityKeepsObjectInFirstGroupOnly() {
    let (a, b, c) = (bar(0), bar(20), bar(40))
    let g1 = ObjectGroup(members: [a.id, b.id])
    let g2 = ObjectGroup(members: [b.id, c.id])
    let g3 = ObjectGroup(members: [b.id, c.id, a.id, bar(60).id])
    let fixed = repaired(SketchDocument(objects: [a, b, c], groups: [g1, g2, g3]))
    #expect(fixed.groups == [g1])
    #expect(jointIntegrityEdits(in: fixed).isEmpty)
}
