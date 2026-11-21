import UIKit
import SketchCore

/// Pin tool, lock in place, group / ungroup.
extension CanvasView {
    /// Pin-tool release. A tap on a hinge adds the bodies under its pivot that it does not hold yet, or, when it
    /// holds them all, toggles its ground. Otherwise (locks never intercept) every body under the (grid-snapped)
    /// spot is joined on one pivot. Empty canvas does nothing.
    func pinTap(at viewPoint: CGPoint) {
        let raw = worldPoint(viewPoint)
        let doc = model.document
        let spot = snapsToGrid ? snap(raw, grid: ShapeController.gridSize) : raw
        // An existing hinge at the tap, or at the snapped spot, is completed or toggled; never stack a second one.
        for probe in (spot == raw ? [raw] : [raw, spot]) {
            // Ring only: a tap on the ground mark pins the body there instead of releasing the pin.
            let reach = JointGeometry.ringRadius + Self.hitSlop / (Viewport.pointsPerMillimetre * currentViewport.zoom)
            let hinge = hitObjects(atWorld: probe).last {
                if case .joint(let j) = $0 { j.kind == .hinge && probe.distance(to: j.position) <= reach } else { false }
            }
            if case .joint(let j)? = hinge {
                let added = pinEdits(at: j.position, under: bodyObjects(at: j.position), in: doc)
                if added.isEmpty {
                    model.perform(toggleGroundEdits(joint: j.id, in: doc), actionName: j.grounded ? "Release Pin" : "Pin to Background")
                } else {
                    model.perform(added, actionName: "Add Pin")
                }
                return
            }
        }
        let under = bodyObjects(at: spot)
        let bodies = Set(under.map { bodyID(of: $0, in: doc) })
        model.perform(pinEdits(at: spot, under: under, in: doc), actionName: bodies.count == 1 ? "Pin to Background" : "Add Pin")
    }

    /// Objects hit at `point` that can be pinned (no wires, no joints), bottom to top.
    private func bodyObjects(at point: Vec2) -> [ObjectID] {
        hitObjects(atWorld: point).filter { if case .wire = $0 { false } else if case .joint = $0 { false } else { true } }
            .map(\.id)
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

    /// Drops ids that left the document (e.g. a hinge integrity removed), then expands to whole groups.
    private func refreshSelection() {
        let existing = Set(model.document.objects.map(\.id))
        selection.ids = expandedToGroups(selection.ids.intersection(existing))
    }

    public func groupSelection() {
        model.perform(groupEdits(selection.ids, in: model.document), actionName: "Group")
        refreshSelection()
    }

    /// Dissolves every group the selection touches, as one undo step.
    public func ungroupSelection() {
        let selected = Set(selectedBodyObjects.map(\.id))
        var doc = model.document
        var edits: [SceneEdit] = []
        for g in doc.groups where g.members.contains(where: selected.contains) {
            let members = Set(g.members)
            let step = ungroupEdits(group: g.id, objectsAt: { [self] p in
                hitObjects(atWorld: p, tolerance: Joint.radius).map(\.id).filter(members.contains)
            }, in: doc)
            for e in step { _ = e.apply(to: &doc) }
            edits += step
        }
        model.perform(edits, actionName: "Ungroup")
        refreshSelection()
    }

    public func toggleLockSelection() {
        guard selectionCanLock, let first = selectedBodyObjects.first else { return }
        model.perform(toggleLockEdits(object: first.id, in: model.document),
                      actionName: selectionIsLocked ? "Unlock" : "Lock in Place")
        refreshSelection()
    }
}
