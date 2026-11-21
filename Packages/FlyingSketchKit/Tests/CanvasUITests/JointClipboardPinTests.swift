import UIKit
import Testing
import SketchCore
@testable import CanvasUI

@MainActor private func canvas(_ doc: SketchDocument) -> (CanvasView, DocumentModel) {
    let m = DocumentModel(document: doc)
    let v = CanvasView(model: m)
    v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    v.layoutIfNeeded()
    return (v, m)
}

private func joints(_ doc: SketchDocument) -> [Joint] { doc.objects.compactMap { if case .joint(let j) = $0 { j } else { nil } } }
private func shapes(_ doc: SketchDocument) -> [ShapeObject] { doc.objects.compactMap { if case .shape(let s) = $0 { s } else { nil } } }

private func bar(_ x: Double) -> ShapeObject { ShapeObject(kind: .line, start: Vec2(x: x, y: 0), end: Vec2(x: x + 10, y: 0)) }

/// Copies of `before` in `after` (everything new).
private func added(_ after: SketchDocument, _ before: SketchDocument) -> SketchDocument {
    let old = Set(before.objects.map(\.id))
    return SketchDocument(objects: after.objects.filter { !old.contains($0.id) })
}

@Suite(.serialized) @MainActor struct JointClipboardPinTests {
    private func clearPasteboard() {
        let pb = UIPasteboard(name: UIPasteboard.Name("flysketch.joint.pin.tests"), create: true)!
        pb.items = []
        Clipboard.pasteboard = pb
    }

    // MARK: Copy / duplicate carry implied joints

    @Test func duplicatingBothBarsCopiesTheirHinge() {
        let (a, b) = (bar(0), bar(10))
        let hinge = Joint(position: Vec2(x: 10, y: 0), anchors: [JointAnchor(object: a.id, point: Vec2(x: 10, y: 0)),
                                                                  JointAnchor(object: b.id, point: Vec2(x: 10, y: 0))])
        let doc = SketchDocument(objects: [.shape(a), .shape(b), .joint(hinge)])
        let (v, m) = canvas(doc)
        v.selection.ids = [a.id, b.id] // the hinge is NOT selected
        v.duplicateSelection()
        let new = added(m.document, doc)
        let copiedShapes = Set(shapes(new).map(\.id))
        #expect(copiedShapes.count == 2)
        #expect(joints(new).count == 1)
        #expect(Set(joints(new)[0].anchors.map(\.object)) == copiedShapes)
        #expect(jointIntegrityEdits(in: m.document).isEmpty)
        m.undoManager.undo()
        #expect(m.document == doc)
    }

    @Test func duplicatingOneBarOfTwoDropsTheHinge() {
        let (a, b) = (bar(0), bar(10))
        let hinge = Joint(position: Vec2(x: 10, y: 0), anchors: [JointAnchor(object: a.id, point: Vec2(x: 10, y: 0)),
                                                                  JointAnchor(object: b.id, point: Vec2(x: 10, y: 0))])
        let doc = SketchDocument(objects: [.shape(a), .shape(b), .joint(hinge)])
        let (v, m) = canvas(doc)
        v.selection.ids = [a.id]
        v.duplicateSelection()
        let new = added(m.document, doc)
        #expect(shapes(new).count == 1)
        #expect(joints(new).isEmpty)
    }

    @Test func copyPasteCarriesHingeOfSelectedBars() {
        clearPasteboard()
        let (a, b) = (bar(0), bar(10))
        let hinge = Joint(position: Vec2(x: 10, y: 0), anchors: [JointAnchor(object: a.id, point: Vec2(x: 10, y: 0)),
                                                                  JointAnchor(object: b.id, point: Vec2(x: 10, y: 0))])
        let doc = SketchDocument(objects: [.shape(a), .shape(b), .joint(hinge)])
        let (src, _) = canvas(doc)
        src.selection.ids = [a.id, b.id]
        src.copySelection()
        let (dst, dm) = canvas(SketchDocument())
        dst.paste()
        #expect(shapes(dm.document).count == 2)
        #expect(joints(dm.document).count == 1)
        #expect(jointIntegrityEdits(in: dm.document).isEmpty)
    }

    @Test func groundedPinOnSingleCopiedBarIsCopied() {
        let a = bar(0)
        let pin = Joint(position: Vec2(x: 0, y: 0), anchors: [JointAnchor(object: a.id, point: Vec2(x: 0, y: 0))], grounded: true)
        let doc = SketchDocument(objects: [.shape(a), .joint(pin)])
        let (v, m) = canvas(doc)
        v.selection.ids = [a.id]
        v.duplicateSelection()
        let new = added(m.document, doc)
        #expect(joints(new).count == 1 && joints(new)[0].grounded)
        #expect(joints(new)[0].anchors.map(\.object) == shapes(new).map(\.id))
    }

    @Test func lockOfCopiedBodyIsCopied() {
        let a = bar(0)
        let base = SketchDocument(objects: [.shape(a)])
        var doc = base
        for e in toggleLockEdits(object: a.id, in: base) { _ = e.apply(to: &doc) }
        #expect(joints(doc).first?.kind == .fixed)
        let (v, m) = canvas(doc)
        v.selection.ids = [a.id]
        v.duplicateSelection()
        let new = added(m.document, doc)
        #expect(joints(new).count == 1 && joints(new)[0].kind == .fixed)
        #expect(joints(new)[0].anchors.map(\.object) == shapes(new).map(\.id))
    }

    @Test func lockOnGroupedBodyIsCopiedWithWholeGroup() {
        let (a, b) = (bar(0), bar(10))
        var doc = SketchDocument(objects: [.shape(a), .shape(b)], groups: [ObjectGroup(members: [a.id, b.id])])
        for e in toggleLockEdits(object: a.id, in: doc) { _ = e.apply(to: &doc) }
        let (v, m) = canvas(doc)
        v.selection.ids = [a.id, b.id]
        v.duplicateSelection()
        let new = added(m.document, doc)
        #expect(joints(new).count == 1 && joints(new)[0].kind == .fixed)
        #expect(m.document.groups.count == 2)
        #expect(jointIntegrityEdits(in: m.document).isEmpty)
    }

    @Test func pinOnPartiallySelectedGroupIsNotCopied() {
        let (a, b) = (bar(0), bar(10))
        let pin = Joint(position: Vec2(x: 0, y: 0), anchors: [JointAnchor(object: a.id, point: Vec2(x: 0, y: 0))], grounded: true)
        let doc = SketchDocument(objects: [.shape(a), .shape(b), .joint(pin)], groups: [ObjectGroup(members: [a.id, b.id])])
        let (v, m) = canvas(doc)
        v.selection.ids = [a.id] // programmatic: bypasses group expansion
        v.duplicateSelection()
        #expect(joints(added(m.document, doc)).isEmpty)
    }

    // MARK: Pasting twice

    @Test func pastingTwiceGivesDistinctIDsAndRightAnchors() {
        clearPasteboard()
        let fb = fourBarDocument()
        var doc = fb.doc
        doc.groups = [ObjectGroup(members: [fb.crank, fb.rocker])]
        let (src, _) = canvas(doc)
        src.selection.ids = Set(doc.objects.map(\.id))
        src.copySelection()
        let (dst, dm) = canvas(SketchDocument())
        dst.paste()
        let first = dm.document
        dst.paste()
        let second = dm.document
        #expect(shapes(second).count == 6 && joints(second).count == 8)
        #expect(second.groups.count == 2)
        #expect(second.groups[0].id != second.groups[1].id)
        #expect(Set(second.objects.map(\.id)).count == second.objects.count)
        #expect(Set(second.groups.flatMap(\.members)).count == 4)
        let firstIDs = Set(first.objects.map(\.id))
        let secondNew = second.objects.filter { !firstIDs.contains($0.id) }
        let secondShapeIDs = Set(shapes(SketchDocument(objects: secondNew)).map(\.id))
        // Each paste's joints anchor only on that paste's own shapes.
        for j in joints(first) { #expect(j.anchors.allSatisfy { firstIDs.contains($0.object) }) }
        for j in joints(SketchDocument(objects: secondNew)) { #expect(j.anchors.allSatisfy { secondShapeIDs.contains($0.object) }) }
        #expect(joints(first).map(\.id).allSatisfy { id in !secondNew.contains { $0.id == id } })
        #expect(jointIntegrityEdits(in: second).isEmpty)
        for g in second.groups { #expect(g.members.allSatisfy { id in second.objects.contains { $0.id == id } }) }
    }

    // MARK: Foreign payloads

    private func twoBars() -> (ShapeObject, ShapeObject) { (bar(0), bar(10)) }

    @Test func sanitizedDropsEmptyGroup() {
        let (a, b) = twoBars()
        let safe = Clipboard.sanitized([.shape(a), .shape(b)], assets: [:], definitions: [:],
                                       groups: [ObjectGroup(members: [])])
        #expect(safe.groups.isEmpty)
    }

    @Test func sanitizedDropsSingleMemberAndMissingMemberGroups() {
        let (a, b) = twoBars()
        let safe = Clipboard.sanitized([.shape(a), .shape(b)], assets: [:], definitions: [:],
                                       groups: [ObjectGroup(members: [a.id]), ObjectGroup(members: [a.id, ObjectID.new()])])
        #expect(safe.groups.isEmpty)
    }

    @Test func sanitizedDropsHingeWithAnchorOutsidePayload() {
        let (a, _) = twoBars()
        let hinge = Joint(position: .zero, anchors: [JointAnchor(object: a.id, point: .zero),
                                                      JointAnchor(object: ObjectID.new(), point: .zero)])
        let pin = Joint(position: .zero, anchors: [JointAnchor(object: ObjectID.new(), point: .zero)], grounded: true)
        let safe = Clipboard.sanitized([.shape(a), .joint(hinge), .joint(pin)], assets: [:], definitions: [:])
        #expect(safe.objects.map(\.id) == [a.id])
    }

    @Test func sanitizedDropsJointAnchoredOnJointOrWire() {
        let (a, b) = twoBars()
        let inner = Joint(position: .zero, anchors: [JointAnchor(object: a.id, point: .zero), JointAnchor(object: b.id, point: .zero)])
        let wire = Wire(start: WireEnd(position: .zero), end: WireEnd(position: Vec2(x: 5, y: 0)))
        let onJoint = Joint(position: .zero, anchors: [JointAnchor(object: inner.id, point: .zero)], grounded: true)
        let onWire = Joint(position: .zero, anchors: [JointAnchor(object: wire.id, point: .zero)], grounded: true)
        let safe = Clipboard.sanitized([.shape(a), .shape(b), .joint(inner), .wire(wire), .joint(onJoint), .joint(onWire)],
                                       assets: [:], definitions: [:])
        #expect(Set(safe.objects.map(\.id)) == [a.id, b.id, inner.id, wire.id])
    }

    @Test func sanitizedDropsInvalidJointShapes() {
        let (a, b) = twoBars()
        let loneHinge = Joint(position: .zero, anchors: [JointAnchor(object: a.id, point: .zero)]) // ungrounded, 1 anchor
        let badLock = Joint(kind: .fixed, position: .zero, anchors: [JointAnchor(object: a.id, point: .zero),
                                                                      JointAnchor(object: b.id, point: .zero)], grounded: true)
        let noAnchors = Joint(position: .zero, anchors: [], grounded: true)
        let safe = Clipboard.sanitized([.shape(a), .shape(b), .joint(loneHinge), .joint(badLock), .joint(noAnchors)],
                                       assets: [:], definitions: [:])
        #expect(Set(safe.objects.map(\.id)) == [a.id, b.id])
    }

    @Test func sanitizedKeepsObjectInFirstGroupAndDropsCollidingGroupIDs() {
        let (a, b) = twoBars()
        let c = bar(20)
        let g1 = ObjectGroup(members: [a.id, b.id])
        let overlapping = ObjectGroup(members: [b.id, c.id])
        let collides = ObjectGroup(id: c.id, members: [a.id, b.id])
        let duplicateID = ObjectGroup(id: g1.id, members: [b.id, c.id])
        let safe = Clipboard.sanitized([.shape(a), .shape(b), .shape(c)], assets: [:], definitions: [:],
                                       groups: [g1, overlapping, collides, duplicateID])
        #expect(safe.groups == [g1])
    }

    @Test func sanitizedCollapsesDuplicateObjectIDs() {
        let a = bar(0)
        let safe = Clipboard.sanitized([.shape(a), .shape(a)], assets: [:], definitions: [:])
        #expect(safe.objects.count == 1)
    }

    @Test func pasteOfHostilePayloadInsertsNothingHostile() throws {
        clearPasteboard()
        let (a, _) = twoBars()
        let hinge = Joint(position: .zero, anchors: [JointAnchor(object: a.id, point: .zero),
                                                      JointAnchor(object: ObjectID.new(), point: .zero)])
        Clipboard.write([.shape(a), .joint(hinge)], assets: [:], groups: [ObjectGroup(members: []), ObjectGroup(members: [a.id])])
        let (v, m) = canvas(SketchDocument())
        v.paste()
        #expect(shapes(m.document).count == 1)
        #expect(joints(m.document).isEmpty)
        #expect(m.document.groups.isEmpty)
        #expect(jointIntegrityEdits(in: m.document).isEmpty)
    }
}
