import UIKit
import SketchCore
import MechKit

/// One mechanism drag: the solver session plus what it needs to commit or cancel. Every frame is relative to the
/// drag-start document (`objects`, `groups`).
struct MechanismSession {
    /// nil when no solver session could be made (e.g. over `MechanismDrag.maxBodies`): the touch can still tap.
    let drag: MechanismDrag?
    let grab: Vec2
    let objects: [SceneObject]
    let groups: [ObjectGroup]
    /// Farthest the touch got from the grab point (mm); a drag that comes back is still a drag, not a tap.
    var travel = 0.0
}

/// One drag of a selected pin.
struct PinMoveSession {
    let original: Joint
    let grab: Vec2
    /// Farthest the touch got from the grab point (mm).
    var travel = 0.0
    /// Pin as previewed.
    var moved: Joint
}

/// Selection-mode routing for pinned objects, mechanism drags and pin drags.
extension CanvasView {
    var mechanismDrag: MechanismDrag? { mechanismSession?.drag }

    /// Selection box and handles are hidden while rotating, dragging a mechanism or moving a pin.
    var selectionChromeHidden: Bool { rotator.isActive || mechanismDrag != nil || pinMoveSession != nil }

    /// Whether rotating the selection would break a pin (quarter turns are then unavailable).
    var selectionIsPinned: Bool { selectionIsPinnedToOutside(selection.ids, in: model.document) }

    /// Whether the rotate handle would break a pin: the selection plus every part plugged into it, with their whole
    /// groups, is pinned to anything outside (`rotateObjects` leaves a pinned plugged body behind, unplugged, so the
    /// handle is hidden instead). Runs on every overlay update (pan / pinch frames too), so a joint-free document
    /// skips the contact search entirely.
    var rotationIsPinned: Bool {
        let doc = model.document
        guard doc.objects.contains(where: { if case .joint = $0 { true } else { false } }) else { return false }
        let parts = Set(selectedObjects.filter { if case .part = $0 { true } else { false } }.map(\.id))
        let ids = parts.isEmpty ? selection.ids : selection.ids.union(expandedToGroups(carriedParts(by: parts, in: doc)))
        return selectionIsPinnedToOutside(ids, in: doc)
    }

    /// Quarter turns spin a part about its own centre without moving pins, so they are unavailable when any
    /// selected part is anchored (directly or through its group) or the selection is pinned to outside.
    var selectionCanQuarterTurn: Bool {
        guard selectionContainsParts, !selectionIsPinned else { return false }
        let doc = model.document
        let pinned = pinnedBodies(in: doc)
        return !selectedObjects.contains { o in
            if case .part = o { pinned.contains(bodyID(of: o.id, in: doc)) } else { false }
        }
    }

    // MARK: Routing

    /// Selected pin under `p`, topmost; only when the selection holds nothing but pins (a selected bar or
    /// mechanism grabbed near a hinge drags the body, not the pin).
    func selectedJoint(at p: CGPoint) -> ObjectID? {
        guard !selection.ids.isEmpty,
              selectedObjects.allSatisfy({ if case .joint = $0 { true } else { false } }) else { return nil }
        return hitObjects(atWorld: worldPoint(p)).last { o in
            if case .joint = o { selection.ids.contains(o.id) } else { false }
        }?.id
    }

    /// A touch at `p` inside the selection: a free move when the selection covers whole mechanisms (or holds no
    /// pinned object); a mechanism drag on a selected pinned body; a move of the loose objects on a loose one, or
    /// off the selected objects when the selection has loose ones (an unengaged move is a tap: `selectionTap`);
    /// else `.pending`, as outside the box (a tap re-targets or clears, a drag lassoes).
    func selectionDrag(at p: CGPoint) -> Interaction? {
        let doc = model.document
        if selectionCoversWholeMechanisms(selection.ids, in: doc) { return .move }
        let hit = hitObjects(atWorld: worldPoint(p)).last { o in
            if case .joint = o { false } else { selection.ids.contains(o.id) }
        }
        guard let hit else { return freeMoveIDs().isEmpty ? .pending(start: p) : .move }
        return pinnedBodies(in: doc).contains(bodyID(of: hit.id, in: doc)) ? .mechanism(hit.id) : .move
    }

    /// Ids a free move drags: the whole selection when it covers whole mechanisms, else only its loose objects
    /// (pinned bodies and joints stay).
    func freeMoveIDs() -> Set<ObjectID> {
        let doc = model.document
        if selectionCoversWholeMechanisms(selection.ids, in: doc) { return selection.ids }
        let pinned = pinnedBodies(in: doc)
        return Set(selectedObjects.filter { o in
            if case .joint = o { return false }
            return !pinned.contains(bodyID(of: o.id, in: doc))
        }.map(\.id))
    }

    /// Bodies anchored by any joint.
    func pinnedBodies(in doc: SketchDocument) -> Set<ObjectID> {
        var result = Set<ObjectID>()
        for case .joint(let j) in doc.objects { result.formUnion(j.anchors.map { bodyID(of: $0.object, in: doc) }) }
        return result
    }

    private var minTravel: Double { Double(Self.legMinTravel) / (Viewport.pointsPerMillimetre * currentViewport.zoom) }

    // MARK: Mechanism drag

    /// Starts dragging `object`'s mechanism, grabbed at world `world`. Without a solver session (no joint, too many
    /// bodies) nothing moves, but the release is still a tap.
    func beginMechanismDrag(object: ObjectID, at world: Vec2) {
        cancelMechanismDrag()
        let doc = model.document
        let drag = MechanismDrag(grabbing: object, at: world, in: doc)
        mechanismSession = MechanismSession(drag: drag, grab: world, objects: doc.objects, groups: doc.groups)
        updateSelectionOverlay()
    }

    func moveMechanism(to world: Vec2) {
        guard var session = mechanismSession else { return }
        session.travel = max(session.travel, world.distance(to: session.grab))
        mechanismSession = session
        guard let drag = session.drag else { return }
        renderer.setMovePreview(ids: [], offset: .zero, replacing: drag.move(to: world))
    }

    /// Commits the previewed drag as "Move Mechanism"; a tap (travel under 4 pt) or no change makes no edit.
    func endMechanismDrag() {
        guard let session = mechanismSession else { return }
        let edits = session.drag?.replacements ?? []
        clearMechanismDrag() // same transaction as the commit (see touchesEnded)
        if session.travel < minTravel {
            selectionTap(atWorld: session.grab)
            return
        }
        guard !edits.isEmpty else { return }
        model.perform(.replace(edits), actionName: "Move Mechanism")
        updateSelectionOverlay()
    }

    func cancelMechanismDrag() {
        guard mechanismSession != nil else { return }
        clearMechanismDrag()
    }

    private func clearMechanismDrag() {
        mechanismSession = nil
        renderer.setMovePreview(ids: [], offset: .zero)
        updateSelectionOverlay()
    }

    // MARK: Pin move

    /// Starts dragging the selected pin `id`, grabbed at world `world`.
    func beginPinMove(_ id: ObjectID, at world: Vec2) {
        cancelPinMove()
        guard case .joint(let j)? = model.document.objects.first(where: { $0.id == id }) else { return }
        pinMoveSession = PinMoveSession(original: j, grab: world, moved: j)
        updateSelectionOverlay()
    }

    func movePin(to world: Vec2) {
        guard var session = pinMoveSession else { return }
        session.travel = max(session.travel, world.distance(to: session.grab))
        session.moved = Self.joint(session.original, movedTo: pinTarget(session, world))
        pinMoveSession = session
        renderer.setMovePreview(ids: [], offset: .zero, replacing: [.joint(session.moved)])
    }

    /// Commits "Move Pin" for a release at `world`; a tap (travel under 4 pt) or no change makes no edit.
    func endPinMove(at world: Vec2) {
        guard let session = pinMoveSession else { return }
        let isTap = max(session.travel, world.distance(to: session.grab)) < minTravel
        let target = pinTarget(session, world)
        clearPinMove() // same transaction as the commit (see touchesEnded)
        if isTap {
            selectionTap(atWorld: session.grab)
            return
        }
        let moved = Self.joint(session.original, movedTo: target)
        guard moved != session.original else { return }
        model.perform(.replace([.joint(moved)]), actionName: "Move Pin")
        updateSelectionOverlay()
    }

    func cancelPinMove() {
        guard pinMoveSession != nil else { return }
        clearPinMove()
    }

    private func clearPinMove() {
        pinMoveSession = nil
        renderer.setMovePreview(ids: [], offset: .zero)
        updateSelectionOverlay()
    }

    private func pinTarget(_ session: PinMoveSession, _ world: Vec2) -> Vec2 {
        let p = session.original.position + (world - session.grab)
        return snapsToGrid ? snap(p, grid: ShapeController.gridSize) : p
    }

    /// `j` with its position and every anchor point at `p` (the bodies do not move).
    private static func joint(_ j: Joint, movedTo p: Vec2) -> Joint {
        var moved = j
        moved.position = p
        for i in moved.anchors.indices { moved.anchors[i].point = p }
        return moved
    }

    // MARK: Outside changes

    /// A document change from outside (e.g. toolbar undo) under a mechanism or pin drag cancels it.
    func cancelPinnedDragsIfChanged(_ doc: SketchDocument) {
        if let s = mechanismSession, s.objects != doc.objects || s.groups != doc.groups { cancelMechanismDrag() }
        if let s = pinMoveSession, doc.objects.first(where: { $0.id == s.original.id }) != .joint(s.original) {
            cancelPinMove()
        }
    }
}
