import UIKit
import SketchCore

/// Pin tool, lock in place, group / ungroup.
extension CanvasView {
    /// Pin-tool release: a tap on a pin toggles its ground, otherwise every body under the (grid-snapped) spot is
    /// joined on one pivot. Empty canvas does nothing.
    func pinTap(at viewPoint: CGPoint) {
        let raw = worldPoint(viewPoint)
        let doc = model.document
        if let joint = hitObjects(atWorld: raw).last(where: { if case .joint = $0 { true } else { false } }),
           case .joint(let j) = joint {
            model.perform(toggleGroundEdits(joint: j.id, in: doc), actionName: j.grounded ? "Release Pin" : "Pin to Background")
            return
        }
        let spot = snapsToGrid ? snap(raw, grid: ShapeController.gridSize) : raw
        let under = hitObjects(atWorld: spot).filter { if case .wire = $0 { false } else if case .joint = $0 { false } else { true } }
            .map(\.id)
        let bodies = Set(under.map { bodyID(of: $0, in: doc) })
        model.perform(pinEdits(at: spot, under: under, in: doc), actionName: bodies.count == 1 ? "Pin to Background" : "Add Pin")
    }

    /// `ids` plus every member of any group they belong to.
    func expandedToGroups(_ ids: Set<ObjectID>) -> Set<ObjectID> {
        model.document.groups.reduce(ids) { acc, g in
            g.members.contains(where: ids.contains) ? acc.union(g.members) : acc
        }
    }

    // MARK: Selection state

    /// Selected bodies' objects: joints and wires never count.
    private var selectedBodyObjects: [SceneObject] {
        selectedObjects.filter { if case .wire = $0 { false } else if case .joint = $0 { false } else { true } }
    }

    var selectionCanGroup: Bool { !groupEdits(selection.ids, in: model.document).isEmpty }

    var selectionCanUngroup: Bool {
        let selected = Set(selectedBodyObjects.map(\.id))
        return model.document.groups.contains { $0.members.contains(where: selected.contains) }
    }

    var selectionCanLock: Bool {
        let doc = model.document
        return Set(selectedBodyObjects.map { bodyID(of: $0.id, in: doc) }).count == 1
    }

    /// Whether the selected body already has a fixed joint (menu shows "Unlock").
    var selectionIsLocked: Bool {
        guard let first = selectedBodyObjects.first else { return false }
        let doc = model.document
        let members = bodyMembers(bodyID(of: first.id, in: doc), in: doc)
        return doc.objects.contains { o in
            guard case .joint(let j) = o, j.kind == .fixed else { return false }
            return j.anchors.contains { members.contains($0.object) }
        }
    }

    // MARK: Actions

    public func groupSelection() {
        model.perform(groupEdits(selection.ids, in: model.document), actionName: "Group")
        selection.ids = expandedToGroups(selection.ids)
    }

    /// Dissolves every group the selection touches, as one undo step.
    public func ungroupSelection() {
        let selected = Set(selectedBodyObjects.map(\.id))
        var doc = model.document
        var edits: [SceneEdit] = []
        for g in doc.groups where g.members.contains(where: selected.contains) {
            let step = ungroupEdits(group: g.id, objectsAt: { [self] p in hitObjects(atWorld: p).map(\.id) }, in: doc)
            for e in step { _ = e.apply(to: &doc) }
            edits += step
        }
        model.perform(edits, actionName: "Ungroup")
    }

    public func toggleLockSelection() {
        guard selectionCanLock, let first = selectedBodyObjects.first else { return }
        model.perform(toggleLockEdits(object: first.id, in: model.document),
                      actionName: selectionIsLocked ? "Unlock" : "Lock in Place")
    }
}
