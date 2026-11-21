import UIKit
import Testing
import SketchCore
@testable import CanvasUI

private func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-6) -> Bool { a.distance(to: b) <= tol }

@MainActor private func canvas(_ doc: SketchDocument) -> (CanvasView, DocumentModel) {
    let m = DocumentModel(document: doc)
    let v = CanvasView(model: m)
    v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    v.layoutIfNeeded()
    return (v, m)
}

private func joints(_ doc: SketchDocument) -> [Joint] { doc.objects.compactMap { if case .joint(let j) = $0 { j } else { nil } } }
private func shapes(_ doc: SketchDocument) -> [ShapeObject] { doc.objects.compactMap { if case .shape(let s) = $0 { s } else { nil } } }

@Suite(.serialized) @MainActor struct JointClipboardTests {
    /// Private pasteboard: the general one is not authorised in the test host.
    private func clearPasteboard() {
        let pb = UIPasteboard(name: UIPasteboard.Name("flysketch.joint.tests"), create: true)!
        pb.items = []
        Clipboard.pasteboard = pb
    }

    @Test func duplicateCopiesWholeMechanism() {
        let fb = fourBarDocument()
        let (v, m) = canvas(fb.doc)
        v.selection.ids = Set(fb.doc.objects.map(\.id))
        v.duplicateSelection()
        let doc = m.document
        #expect(shapes(doc).count == 6)
        #expect(joints(doc).count == 8)
        let originals = Set(fb.doc.objects.map(\.id))
        let copyIDs = Set(doc.objects.map(\.id)).subtracting(originals)
        #expect(copyIDs.count == 7)
        #expect(v.selection.ids == copyIDs)
        let copiedShapes = Set(shapes(doc).map(\.id)).intersection(copyIDs)
        let offset = CanvasView.duplicateOffset
        for j in joints(doc) where copyIDs.contains(j.id) {
            #expect(j.anchors.allSatisfy { copiedShapes.contains($0.object) })
            let original = joints(fb.doc).first { $0.kind == j.kind && $0.grounded == j.grounded && near($0.position + offset, j.position) }
            #expect(original != nil)
            #expect(original?.anchors.count == j.anchors.count)
            for a in j.anchors { #expect(near(a.point, j.position)) }
        }
        #expect(joints(doc).filter { copyIDs.contains($0.id) && $0.grounded }.count == 2)
        #expect(jointIntegrityEdits(in: doc).isEmpty)
        m.undoManager.undo()
        #expect(m.document == fb.doc)
        #expect(!m.undoManager.canUndo)
    }

    @Test func duplicateDropsPinsToOutside() {
        let fb = fourBarDocument()
        let (v, m) = canvas(fb.doc)
        v.selection.ids = [fb.crank, fb.coupler, fb.jointB]
        v.duplicateSelection()
        let doc = m.document
        let copyIDs = Set(doc.objects.map(\.id)).subtracting(fb.doc.objects.map(\.id))
        // The pin at A (grounded, only on the crank) goes with the copied crank even though it was not selected.
        let copiedJoints = joints(doc).filter { copyIDs.contains($0.id) }
        #expect(copiedJoints.count == 2)
        #expect(copyIDs.count == 4)
        let copiedShapes = Set(shapes(doc).map(\.id)).intersection(copyIDs)
        let hingeB = copiedJoints.first { !$0.grounded }
        #expect(hingeB?.anchors.count == 2)
        #expect(copiedJoints.allSatisfy { $0.anchors.allSatisfy { copiedShapes.contains($0.object) } })
        #expect(copiedJoints.filter(\.grounded).count == 1)
        #expect(jointIntegrityEdits(in: doc).isEmpty)
    }

    @Test func copyPasteKeepsGroups() throws {
        clearPasteboard()
        let fb = fourBarDocument()
        var doc = fb.doc
        let group = ObjectGroup(members: [fb.crank, fb.rocker])
        doc.groups = [group]
        let (v, m) = canvas(doc)
        v.selection.ids = [fb.crank, fb.rocker, fb.jointA, fb.jointD]
        v.copySelection()
        v.paste()
        let after = m.document
        #expect(after.groups.count == 2)
        #expect(after.groups.first == group)
        let new = try #require(after.groups.last)
        #expect(new.id != group.id)
        #expect(new.members.count == 2)
        #expect(Set(new.members).isDisjoint(with: [fb.crank, fb.rocker]))
        #expect(Set(new.members).isSubset(of: v.selection.ids))
        #expect(jointIntegrityEdits(in: after).isEmpty)
        m.undoManager.undo()
        #expect(m.document == doc)
        #expect(!m.undoManager.canUndo)
    }

    @Test func partialGroupSelectionDoesNotCopyGroup() {
        let fb = fourBarDocument()
        var doc = fb.doc
        doc.groups = [ObjectGroup(members: [fb.crank, fb.coupler])]
        let (v, m) = canvas(doc)
        v.selection.ids = [fb.crank] // programmatic: bypasses group expansion
        v.duplicateSelection()
        #expect(m.document.groups == doc.groups)
    }

    @Test func pasteIntoOtherDocumentKeepsJointsAndGroups() {
        clearPasteboard()
        let fb = fourBarDocument()
        var doc = fb.doc
        doc.groups = [ObjectGroup(members: [fb.crank, fb.rocker])]
        let (src, _) = canvas(doc)
        src.selection.ids = Set(doc.objects.map(\.id))
        src.copySelection()
        let (dst, dm) = canvas(SketchDocument())
        dst.paste()
        #expect(shapes(dm.document).count == 3)
        #expect(joints(dm.document).count == 4)
        #expect(dm.document.groups.count == 1)
        #expect(jointIntegrityEdits(in: dm.document).isEmpty)
        #expect(joints(dm.document).filter(\.grounded).count == 2)
    }

    @Test func olderClipboardPayloadDecodes() throws {
        clearPasteboard()
        let fb = fourBarDocument()
        let (src, _) = canvas(fb.doc)
        src.selection.ids = [fb.crank, fb.coupler]
        src.copySelection()
        let data = try #require(Clipboard.pasteboard.data(forPasteboardType: Clipboard.typeIdentifier))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "groups")
        Clipboard.pasteboard.setItems([[Clipboard.typeIdentifier: try JSONSerialization.data(withJSONObject: json)]])
        let (dst, dm) = canvas(SketchDocument())
        dst.paste()
        #expect(shapes(dm.document).count == 2)
        #expect(dm.document.groups.isEmpty)
    }

    @Test func eraseBarCleansPins() {
        let fb = fourBarDocument()
        let m = DocumentModel(document: fb.doc)
        let e = EraserController(model: m)
        e.begin(at: (fb.b + fb.c) / 2, radius: 1)
        e.end()
        #expect(Set(m.document.objects.map(\.id)) == [fb.crank, fb.rocker, fb.jointA, fb.jointD])
        #expect(jointIntegrityEdits(in: m.document).isEmpty)
        m.undoManager.undo()
        #expect(m.document == fb.doc)
        #expect(!m.undoManager.canUndo)
    }

    @Test func eraseGroupedStrokeKeepsPin() {
        func stroke(_ y: Double) -> InkStroke {
            InkStroke(points: [InkPoint(position: Vec2(x: 0, y: y), pressure: 0.5, time: 0),
                               InkPoint(position: Vec2(x: 10, y: y), pressure: 0.5, time: 0.1)], tool: .pen, baseWidth: 0.5)
        }
        let (s1, s2) = (stroke(0), stroke(30))
        let pivot = Vec2(x: 10, y: 0)
        let bar = ShapeObject(kind: .line, start: pivot, end: Vec2(x: 40, y: 0))
        let hinge = Joint(position: pivot, anchors: [JointAnchor(object: s1.id, point: pivot), JointAnchor(object: bar.id, point: pivot)])
        let doc = SketchDocument(objects: [.ink(s1), .ink(s2), .shape(bar), .joint(hinge)],
                                 groups: [ObjectGroup(members: [s1.id, s2.id])])
        let m = DocumentModel(document: doc)
        let e = EraserController(model: m)
        e.begin(at: Vec2(x: 2, y: 0), radius: 1)
        #expect(e.hit == [s1.id])
        e.end()
        #expect(Set(m.document.objects.map(\.id)) == [s2.id, bar.id, hinge.id])
        #expect(joints(m.document).first?.anchors.map(\.object) == [s2.id, bar.id])
        #expect(jointIntegrityEdits(in: m.document).isEmpty)
        m.undoManager.undo()
        #expect(m.document == doc)
    }

    @Test func eraseJoint() {
        let fb = fourBarDocument()
        let m = DocumentModel(document: fb.doc)
        let e = EraserController(model: m)
        // 1 mm outside C, away from both bars meeting there: only the hinge disc is in reach.
        let away = ((fb.b - fb.c).normalized + (fb.d - fb.c).normalized).normalized * -1
        e.begin(at: fb.c + away, radius: 0.3)
        #expect(e.hit == [fb.jointC])
        e.end()
        #expect(Set(m.document.objects.map(\.id)) == Set(fb.doc.objects.map(\.id)).subtracting([fb.jointC]))
    }

    @Test func deleteSelectionWithJoint() {
        let fb = fourBarDocument()
        let (v, m) = canvas(fb.doc)
        v.selection.ids = [fb.jointB]
        v.deleteSelection()
        #expect(Set(m.document.objects.map(\.id)) == Set(fb.doc.objects.map(\.id)).subtracting([fb.jointB]))
        #expect(jointIntegrityEdits(in: m.document).isEmpty)
    }

    @Test func sanitizedDropsDanglingJointsAndGroups() {
        let fb = fourBarDocument()
        let objects = fb.doc.objects.filter { $0.id != fb.rocker } // jointC, jointD reference the rocker
        let groups = [ObjectGroup(members: [fb.crank, fb.coupler]), ObjectGroup(members: [fb.coupler, fb.rocker])]
        let safe = Clipboard.sanitized(objects, assets: [:], definitions: [:], groups: groups)
        // Crank and coupler form one body in the kept group, so the integrity rules also drop the hinge between them.
        #expect(Set(safe.objects.map(\.id)) == [fb.crank, fb.coupler, fb.jointA])
        #expect(safe.groups == [groups[0]])
    }

    @Test func clonedSkipsPartialGroupsAndJoints() {
        let fb = fourBarDocument()
        let picked = fb.doc.objects.filter { [fb.crank, fb.coupler, fb.jointB, fb.jointC].contains($0.id) }
        let groups = [ObjectGroup(members: [fb.coupler, fb.rocker])]
        let out = cloned(picked, groups: groups, by: .zero, into: fb.doc)
        #expect(out.groups.isEmpty)
        #expect(out.objects.count == 3) // jointC needs the rocker
    }
}
