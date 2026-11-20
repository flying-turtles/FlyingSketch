# Wire Bend Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move, add and remove bend points of existing wires via handles on selected wires.

**Architecture:** Pure bend helpers on `Wire` (SketchCore). A `WireBendController` (CanvasUI) owns one drag session and commits one edit, mirroring `LegController`. `CanvasView+WireBends.swift` draws handles, hit-tests them, routes touches and previews through `renderer.setMovePreview`.

**Tech Stack:** Swift 6 strict concurrency, UIKit / Core Animation, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-20-wire-bend-editing-design.md`

## Global Constraints

- Handles show on **every** selected wire, in selection mode only (lasso tool, or finger with `pencilOnly`). Same routing condition as leg ends (`selecting` in `route`).
- Touch-down priority: leg end, bend handle, insert handle, then existing move / lasso / pending.
- Handle hit radius = `legHandleRadius` (≥1 mm, ≥12 pt). Bend handle look = `legHandles` look.
- Insert handle at each segment midpoint (polyline start → bends → end); hidden and not hittable when segment world length < `6 * legHandleRadius` (3 × handle diameter).
- Tap threshold: release travel < 4 pt (`legMinTravel`), converted to mm at current zoom.
- Tap bend → remove, action "Remove Wire Bend". Drag bend → "Move Wire Bend". Drag insert → "Add Wire Bend". Tap insert → no edit.
- Dragged point = original point + (touch − grab), then `snap(_, grid: ShapeController.gridSize)` when `snapsToGrid`.
- Ends (positions, attachments) never change. Each edit is one undo step (`.replace([.wire(w)])`).
- Cancel (second finger, Pencil takeover, window gone) → no edit, preview cleared.
- Package tests: `cd Packages/FlyingSketchKit && xcodebuild test -scheme FlyingSketchKit-Package -destination 'id=08D1B7B4-263D-4479-8F34-C24730978306'` (`swift test` does not work: UIKit). Add `-only-testing:<Target>/<file-or-test>` to narrow.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Handle inside the selection rect: touch on a handle must drag the bend, not move the selection.
2. Bend handle on the same spot as a leg end (wire bend placed on a pin): leg end wins.
3. Release where the bend started (or snapping back to it): no edit, no undo entry.
4. Wire deleted / changed under a drag (document change from elsewhere): release makes no edit, no crash.
5. Handles follow an in-flight selection move (like leg handles) and the bend preview during a drag.

---

### Task 1: Bend geometry on `Wire`

**Files:**
- Modify: `Packages/FlyingSketchKit/Sources/SketchCore/Model/Wire.swift`
- Test: `Packages/FlyingSketchKit/Tests/SketchCoreTests/WireBendGeometryTests.swift`

**Interfaces:**
- Produces (all `public`, on `Wire`, non-mutating, return copies):
  - `func movingBend(_ index: Int, to p: Vec2) -> Wire`
  - `func insertingBend(inSegment segment: Int, at p: Vec2) -> Wire` — segment `s` runs `polyline[s]` → `polyline[s+1]`; new bend becomes `bends[s]`.
  - `func removingBend(_ index: Int) -> Wire`
  - `var segmentMidpoints: [Vec2]` — count = `polyline.count - 1`.
  - Out-of-range index/segment returns `self` unchanged.

- [ ] **Step 1: Write failing tests** in `WireBendGeometryTests.swift`. Wire: start (0,0), bends [(10,0)], end (10,10), start attached `.connector(part: id, connector: "a")`.
  - `movingBendReplacesOnlyThatBend`: `movingBend(0, to: (20,5)).bends == [(20,5)]`; `start`, `end` equal original.
  - `insertingBendInFirstSegment`: `insertingBend(inSegment: 0, at: (5,0)).bends == [(5,0),(10,0)]`.
  - `insertingBendInLastSegment`: `insertingBend(inSegment: 1, at: (10,5)).bends == [(10,0),(10,5)]`.
  - `insertingBendOnStraightWire`: wire without bends, `insertingBend(inSegment: 0, at: p).bends == [p]`.
  - `removingBend`: `removingBend(0).bends == []`, ends unchanged.
  - `segmentMidpoints`: `== [(5,0),(10,5)]`.
  - `outOfRangeIsNoOp`: `movingBend(1,…)`, `removingBend(-1)`, `insertingBend(inSegment: 2,…)` each `== wire`.
- [ ] **Step 2: Run** `-only-testing:SketchCoreTests/WireBendGeometryTests` → FAIL (members missing).
- [ ] **Step 3: Implement** the four members in `Wire.swift`.
- [ ] **Step 4: Run** same → PASS.
- [ ] **Step 5: Commit** `feat(core): wire bend move/insert/remove helpers`.

### Task 2: `WireBendController`

**Files:**
- Create: `Packages/FlyingSketchKit/Sources/CanvasUI/Tools/WireBendController.swift`
- Test: `Packages/FlyingSketchKit/Tests/CanvasUITests/WireBendControllerTests.swift`

**Interfaces:**
- Consumes: Task 1 helpers.
- Produces:
  ```swift
  /// A handle on a selected wire.
  enum WireHandle: Equatable {
      case bend(wire: ObjectID, index: Int)
      case insert(wire: ObjectID, segment: Int)
      var wire: ObjectID { get }
  }
  final class WireBendController {
      init(model: DocumentModel)
      var minDistance: Double      // tap threshold (mm), set by caller
      var snapsToGrid: Bool
      var isActive: Bool { get }
      /// Starts a drag; false (inactive) if wire or index/segment missing.
      @discardableResult func begin(_ handle: WireHandle, grabAt world: Vec2) -> Bool
      /// Preview wire for touch `world`; nil when inactive.
      func move(to world: Vec2) -> Wire?
      /// Commits per Global Constraints; returns whether an edit was made. Always ends the session.
      @discardableResult func end(at world: Vec2) -> Bool
      func cancel()
  }
  ```
- Rules: `begin` stores the wire value and the handle's start point (bend position, or segment midpoint). Tap = `world.distance(to: grab) < minDistance`. Bend tap → `removingBend`. Insert tap → no edit. Drag target = start + (world − grab), snapped if `snapsToGrid`; target equal (≤1e-9) to start → no edit. `end` makes no edit if the document no longer holds a wire with that id equal to the stored value. Preview for an insert drag already contains the inserted bend.

- [ ] **Step 1: Write failing tests** (model with one wire: start (0,0), bends [(10,0)], end (10,10); `minDistance = 0.5`):
  - `dragBendCommitsMove`: begin `.bend(w,0)` grab (10,0), move (14,3), end (14,3) → bends `[(14,3)]`, `undoActionName == "Move Wire Bend"`; undo → `[(10,0)]`.
  - `grabOffsetNoJump`: grab (10.4,0.2), end (12.4,0.2) → bends `[(12,0)]`.
  - `tapBendRemoves`: end at grab + (0.1,0) → bends `[]`, "Remove Wire Bend".
  - `dragInsertAddsBend`: begin `.insert(w,0)` grab (5,0), move to (5,-4) returns wire with bends `[(5,-4),(10,0)]`; end → committed same, "Add Wire Bend".
  - `tapInsertNoEdit`: end at grab → returns false, `canUndo == false`.
  - `snapsToGrid`: `snapsToGrid = true`, drag bend to (13.2, 4.1) → bend equals `snap((13.2,4.1), grid: ShapeController.gridSize)`.
  - `releaseAtStartNoEdit`: drag out then end at grab + (0.6,0) with snap on so it snaps back to (10,0) → false, no undo.
  - `wireChangedUnderDragNoEdit`: begin, then `model.perform(.replace([.wire(other)]))` changing the wire, end far away → false; doc wire equals `other`.
  - `endsUntouched`: after any committed edit, `start`/`end` equal original (attachment included).
  - `cancelNoEdit`: begin, move, cancel → `isActive == false`, no undo.
- [ ] **Step 2: Run** `-only-testing:CanvasUITests/WireBendControllerTests` → FAIL.
- [ ] **Step 3: Implement** `WireBendController.swift`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(canvas): wire bend drag controller`.

### Task 3: Handles, routing and drag on the canvas

**Files:**
- Create: `Packages/FlyingSketchKit/Sources/CanvasUI/Tools/CanvasView+WireBends.swift`
- Modify: `Packages/FlyingSketchKit/Sources/CanvasUI/CanvasView.swift` (properties, layers, `Interaction`, `route`, begin/moved/ended/cancel switches, `allowsUndoTap`)
- Modify: `Packages/FlyingSketchKit/Sources/CanvasUI/Selection/CanvasView+Selection.swift` (`updateSelectionOverlay` also calls `updateWireHandles()`)
- Test: `Packages/FlyingSketchKit/Tests/CanvasUITests/WireBendCanvasTests.swift`

**Interfaces:**
- Consumes: `WireHandle`, `WireBendController` (Task 2); `segmentMidpoints` (Task 1); existing `legEnd(at:)`, `legHandleRadius`, `legMinTravel`, `movedObjects(_:rigid:by:)`, `moveEngaged`, `renderer.setMovePreview`.
- Produces on `CanvasView`:
  - `Interaction.wireBend(WireHandle)`; `allowsUndoTap` returns false for it.
  - `private(set) var bends: WireBendController!` (created in `init`), `var bendPreview: Wire?`.
  - Layers added after `legHandles`: `wireBendHandles: CAShapeLayer` (same style as `legHandles`), `wireInsertHandles: CAShapeLayer` (no fill, accent stroke 1 pt, circle radius 0.6 × handle radius in pt, with a "+" inside).
  - `func selectedWireHandles() -> [(handle: WireHandle, position: Vec2)]` — selected wires in document order, with `bendPreview` replacing its wire and move preview applied as in `selectedLegEnds()`; bends first then inserts per wire; inserts filtered by the 6 × radius rule.
  - `func wireHandle(at p: CGPoint) -> WireHandle?` — nearest within `legHandleRadius`; bend beats insert at equal distance; ties → first in list.
  - `func updateWireHandles()`, `beginWireBendDrag(_:at:)`, `moveWireBend(to:)`, `endWireBendDrag(at:)`, `cancelWireBendDrag()`.
- `route`: after the `legEnd` check: `if selecting, let h = wireHandle(at: p) { return .wireBend(h) }`.
- Begin sets `bends.minDistance = legMinTravel / (pointsPerMillimetre * zoom)` and `bends.snapsToGrid = snapsToGrid`. Move/end/cancel mirror `moveLeg` / `endLegDrag` / `cancelLegDrag` (preview via `renderer.setMovePreview(ids: [], offset: .zero, replacing: [.wire(preview)])`, clear sets `bendPreview = nil`, resets preview, `updateWireHandles()`). The existing single transaction in `touchesEnded` covers commit + clear.

- [ ] **Step 1: Write failing tests** (canvas 1024×1366 as in `SelectionTests`; wire start (0,0), bends [(20,0)], end (20,20); view points via `currentViewport.worldToView`):
  - `handlesOnlyForSelectedWires`: no selection → `selectedWireHandles().isEmpty`; select → contains `.bend(w,0)` at (20,0) and `.insert(w,0)` at (10,0), `.insert(w,1)` at (20,10).
  - `handlesOnAllSelectedWires`: two wires selected → handles for both.
  - `shortSegmentHasNoInsertHandle`: wire start (0,0), end (1,0) selected → no `.insert`; `wireHandle(at:)` at its midpoint is nil.
  - `routeHandleBeatsMove`: lasso tool, wire selected, `route(isPencil: true, at: view(20,0))` is `.wireBend(.bend(w,0))`; at view(10,0) is `.wireBend(.insert(w,0))`; off handles inside selection → `.move`.
  - `routeLegEndBeatsBend`: resistor fixture (as in `LegControllerTests`) and a wire whose bend sits on leg end "a", both selected → route at that point is `.leg`.
  - `noHandlesOutsideSelectionMode`: wire tool, pencil touch at bend → not `.wireBend`.
  - `dragBendEndToEnd`: `beginWireBendDrag(.bend(w,0), at: (20,0))`, `moveWireBend(to: (25,5))` → `bendPreview?.bends == [(25,5)]` and bend handle at (25,5); `endWireBendDrag(at: (25,5))` → doc bends `[(25,5)]`, `bendPreview == nil`.
  - `cancelClearsPreview`: begin, move, `cancelInteraction()` path via `cancelWireBendDrag()` → no undo, `bendPreview == nil`.
  - `undoTapBlockedDuringBendDrag`: `allowsUndoTap(during: .wireBend(.bend(w,0))) == false`.
- [ ] **Step 2: Run** `-only-testing:CanvasUITests/WireBendCanvasTests` → FAIL.
- [ ] **Step 3: Implement** `CanvasView+WireBends.swift` and the `CanvasView.swift` / selection edits.
- [ ] **Step 4: Run** full package suite → PASS (all existing tests too).
- [ ] **Step 5: Build app** `cd ~/coding_projects/FlyingSketch && xcodegen && xcodebuild -scheme FlyingSketch -destination 'id=08D1B7B4-263D-4479-8F34-C24730978306' build` → BUILD SUCCEEDED.
- [ ] **Step 6: Commit** `feat(canvas): edit wire bends via handles on selected wires`.
