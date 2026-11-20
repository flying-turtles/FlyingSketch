# Bodies, Hinges and Motion Implementation Plan (joints step 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pin canvas objects together with hinge pins, lock bodies in place, and drag a pinned body so the whole mechanism moves live with the pins holding.

**Architecture:** A pin is a new canvas object (`Joint`) that stores, per attached object, that object's own copy of the pin point in world mm; a body's copies are only ever moved by that body's rigid transform, so bar lengths cannot drift and no body frames are stored. Groups (several objects moving as one) live in a small document table. A new pure target `MechKit` holds the solver (damped least squares over body poses) and the document-level mechanism logic; `CanvasUI` routes the existing selection drag into it.

**Tech Stack:** Swift 6 strict concurrency, own solver (no third-party / GPL code), UIKit / Core Animation, CoreGraphics export, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-20-mechanical-joints-design.md` (Part 2). Slide / pin-in-slot / tracing / readouts are plan 3: nothing of them here.

## Global Constraints

- Units mm, y-down, angles radians clockwise positive (`Vec2.rotated(by:)`). Every stored object rotation goes through `normalizedAngle`.
- **Body** of an object = its group if it is in one, else the object alone. Wires are never body members or pin anchors. Parts plugged into a body's parts (`carriedParts(by:in:)`, transitively) ride with that body unless they are themselves pinned or grouped.
- **Joint kinds:** `hinge` (shared pivot of 1...n bodies, optionally fixed to the background) and `fixed` ("Lock in place": one body, held at its position and angle).
- A hinge is valid with ≥ 2 anchors on different bodies, or ≥ 1 anchor and `grounded`. Anything less is deleted by the integrity pass in the same edit.
- Pins hold exactly: after every solve the distance between any two anchors of one joint (and to its ground point when grounded) is < 1e-6 mm. Distances between two pin points on the same body never change (they are moved by one rigid transform only).
- What holds still: bodies not dragged stay where they are as far as the pins allow (least total motion); locked and grounded constraints never give.
- Unreachable drag: the mechanism goes as far as it can and stays. Rigid arrangements do not move. No dialogs.
- Always live, no mode: in selection mode a drag that starts on a pinned body is a mechanism drag ("Move Mechanism", one undo step). A selection that contains a whole connected mechanism (all its bodies' objects and all its joints) moves freely as one piece, ground points and locks included. A drag starting on a selected pin moves the pin ("Move Pin").
- A partial selection does not change a mechanism drag: the grabbed body is pulled; loose selected objects stay put. No plug snapping at the end of a mechanism drag.
- Rotate handle and the 90° action are unavailable when the selection is pinned to something outside it: a joint has an anchor inside and an anchor outside the selection, or a grounded / fixed joint holds a selected object while the joint itself is not selected. (Spec says "hidden for locked bodies"; a lock or ground pin that is selected along with its whole mechanism simply rotates with it, like it moves with it.)
- Pins draw above every other object and win taps. Hinge: ring Ø 2.4 mm with centre dot; grounded hinge adds a ground mark below; fixed joint draws a small lock mark. Same marks in PNG / PDF / SVG export. BOM / netlist ignore joints.
- Pin tool: tap joins every body under the spot on one shared pivot; one body under the spot = pinned to the background; tap on an existing pin toggles `grounded`; empty canvas = nothing. Spot snaps to the grid when `snapsToGrid`.
- Group merges bodies (flat groups); hinges whose anchors end up all in one body, and not grounded, are removed. Ungroup re-attaches each anchor to the topmost former member under its point, or drops the anchor when none is there. One undo step each.
- Copy / duplicate: joints whose anchors are all copied are copied (ids remapped); a joint with a non-copied anchor is dropped from the copy. Groups are copied when all members are copied.
- Deleting an object removes its anchors; invalid joints go in the same undo step. Deleting a group's last member removes the group.
- Electrical side unchanged: nets, plugging, wires computed from the moved geometry as before.
- File format: `formatVersion` 4 (adds `joint` objects and `groups`). Versions 1–3 open unchanged; > 4 → `unsupportedVersion`.
- Solver targets: residual < 1e-6 mm; a 50-body chain drag frame solves in < 2 ms on the iPad (test bound on the simulator host: < 10 ms average in a debug test run; record the measured value).
- Package tests: `cd Packages/FlyingSketchKit && xcodebuild test -scheme FlyingSketchKit-Package -destination 'id=08D1B7B4-263D-4479-8F34-C24730978306'`; narrow with `-only-testing:<Target>` (target level only). `swift test` does not work (UIKit).
- Commits end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## Review Focus

1. A long drag session (hundreds of frames, back and forth through near-singular poses such as a fully stretched four-bar): pins never separate, bar lengths unchanged to 1e-9 mm, the mechanism does not flip to its mirror assembly.
2. A mechanism with no background pin (plate + two bars): dragging a bar leaves the plate where it is unless the pins force it.
3. A body containing a breadboard with plugged modules and wires: after a mechanism drag, contacts and wire attachments are identical; undo restores everything in one step.
4. Deleting / erasing / cutting one bar of a mechanism: no orphan anchors or invalid joints remain; undo brings pins back.
5. Old documents (v1–v3) open unchanged; a v4 document with joints and groups round-trips equal; a joint referencing a missing object in a file is repaired on read, not a crash.

---

### Task 1: Solver core (`MechKit`)

**Files:**
- Modify: `Packages/FlyingSketchKit/Package.swift` (target `MechKit`, dependency `SketchCore`; test target `MechKitTests`; library product)
- Create: `Sources/MechKit/Solver.swift`, `Sources/MechKit/LinearAlgebra.swift`
- Test: `Tests/MechKitTests/SolverTests.swift`

**Interfaces:**
- Produces (all `public`, `Sendable`, value types, no UIKit, no globals):
  ```swift
  /// Rigid motion of one body: p -> origin + (p - origin).rotated(by: angle) + translation.
  public struct BodyPose: Equatable, Sendable { public var translation: Vec2; public var angle: Double
      public static let identity: BodyPose
      public func apply(_ p: Vec2, origin: Vec2) -> Vec2 }
  public struct SolverBody: Sendable { public var origin: Vec2; public var isFixed: Bool }
  /// Keeps point `pointA` of body `a` on point `pointB` of body `b` (`b == nil`: `pointB` is a fixed world point).
  public struct PointConstraint: Sendable { public var a: Int; public var pointA: Vec2; public var b: Int?; public var pointB: Vec2 }
  public struct DragTarget: Sendable { public var body: Int; public var point: Vec2; public var target: Vec2 }
  public struct SolveResult: Sendable { public var poses: [BodyPose]; public var residual: Double; public var converged: Bool }
  public enum MechanismSolver {
      /// `initial`: poses to start from (previous frame); points in constraints / drag are given at the identity pose.
      public static func solve(bodies: [SolverBody], constraints: [PointConstraint], drag: DragTarget?,
                               initial: [BodyPose]) -> SolveResult
  }
  ```
- Behaviour: constraints are hard (`residual` = largest constraint distance, must end < 1e-6 when the system is consistent); the drag target and "stay near `initial`" are soft, drag much stronger than stay; angle deviation is scaled by the body's reach (largest distance from `origin` to any of its constraint / drag points, at least 1 mm) so position and angle are comparable. Rank-deficient and redundant constraint sets must not blow up (damped solve). `isFixed` bodies keep `initial`. `converged == false` when the iteration cap is hit with residual ≥ 1e-6: caller keeps the previous poses.

- [ ] **Step 1: Write failing tests** (helper `circleIntersections(c1, r1, c2, r2) -> [Vec2]` in the test file):
  - `twoBodiesOneHingeFollowDrag`: bodies A (origin (0,0)) and B (origin (10,0)), hinge at (5,0), drag B's point (15,0) to (15,6): residual < 1e-6; B's dragged point within 1e-3 of the target.
  - `groundedCrankRotates`: body with ground constraint at (0,0), drag its point (10,0) to (0,10): dragged point ≈ (0,10) (1e-4), angle ≈ π/2.
  - `fourBarMatchesClosedForm`: ground pins A (0,0), D (40,0); crank AB = 10, coupler BC = 35, rocker DC = 25; start with B = (0,-10) and C the `circleIntersections(B,35,D,25)` solution with smaller y. Drag B through crank angles −90° → −60° → −30° → 0° in 5° steps (warm start each frame). At each step: residual < 1e-6; B within 1e-4 of the target; C within 1e-4 of the closed-form intersection on the same side (the one nearer the previous C); |BC| and |DC| equal 35 and 25 within 1e-9.
  - `unreachableTargetStopsAtFullExtension`: grounded crank length 10, drag its end to (100,0): end point ≈ (10,0) (1e-3), converged, residual < 1e-6.
  - `rigidTriangleDoesNotDeform`: three bodies pinned pairwise, one body with two ground constraints; drag another body's point 20 mm away: every pose stays identity within 1e-6.
  - `ungroundedChainMovesLeast`: plate P, bars B1, B2 hinged to P at (0,0) and (20,0), nothing grounded; drag B1's far end by (0,5): P's translation length < 0.5 and |angle| < 0.02; residual < 1e-6.
  - `fixedBodyNeverMoves`: same with `P.isFixed`: P pose == initial exactly.
  - `redundantConstraintsStaySolvable`: parallelogram with a duplicated coupler (redundant): drag moves it, residual < 1e-6, no NaN.
  - `separateMechanismsIndependent`: two unconnected hinged pairs, drag in the first: second pair's poses == initial exactly.
  - `noDragIsIdentityStep`: consistent system, `drag: nil` → poses == initial within 1e-12.
  - `fiftyBodyChainFrameTime`: chain of 50 bars (length 10, first grounded), 60 warm-started frames dragging the tip along a 30 mm arc: every residual < 1e-6; average solve time < 10 ms (print the measured value).
- [ ] **Step 2: Run** `-only-testing:MechKitTests` → FAIL.
- [ ] **Step 3: Implement.** Dense Gauss–Newton / Levenberg–Marquardt on the stacked residual vector (weighted constraint rows, soft drag rows, soft stay rows) followed by constraint-only projection steps until residual < 1e-6 (cap 40 iterations total); own Cholesky / Gaussian elimination in `LinearAlgebra.swift`. Unknowns only for non-fixed bodies.
- [ ] **Step 4: Run** → PASS; full package suite → PASS.
- [ ] **Step 5: Commit** `feat(mech): planar mechanism solver`.

### Task 2: Joint and group model, file format 4

**Files:**
- Create: `Sources/SketchCore/Model/Joint.swift`, `Sources/SketchCore/Model/ObjectGroup.swift`, `Sources/SketchCore/Connectivity/JointEdits.swift`
- Modify: `Sources/SketchCore/Model/SceneObject.swift` (case `.joint`), `Sources/SketchCore/Model/SketchDocument.swift` (`groups`, version 4), `Sources/SketchCore/Edit/SceneEdit.swift` (`.setGroups`), `Sources/SketchCore/Edit/DocumentModel.swift` (no-op check includes `groups`), `Sources/SketchCore/Query/HitTesting.swift`, `Sources/SketchCore/Query/SceneGeometry.swift` (if `contentBounds` switches), `Sources/SketchCore/File/DocumentPackage.swift`, `Sources/SketchCore/Connectivity/PartEdits.swift` (`deletionEdits`)
- Modify to keep the package compiling (drawing arrives in Task 3; here a joint draws nothing): every exhaustive `switch` over `SceneObject` in `Sources/CanvasUI`, `Sources/ExportKit`, `Sources/NetKit`, `Sources/PartsKit`.
- Test: `Tests/SketchCoreTests/JointModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum JointKind: String, Codable, Sendable { case hinge, fixed }
  public struct JointAnchor: Hashable, Codable, Sendable { public var object: ObjectID; public var point: Vec2 }
  public struct Joint: Hashable, Codable, Sendable {
      public var id: ObjectID; public var kind: JointKind
      /// Display position; the fixed world point when `grounded`.
      public var position: Vec2
      public var anchors: [JointAnchor]
      public var grounded: Bool
      public static let radius = 1.2   // mm
  }
  public struct ObjectGroup: Hashable, Codable, Sendable { public var id: ObjectID; public var members: [ObjectID] }
  // SketchDocument.groups: [ObjectGroup]  (init parameter `groups: [ObjectGroup] = []`, last)
  // SceneEdit.setGroups([ObjectGroup])    (replaces the whole table; inverse restores the previous table)
  public func bodyID(of object: ObjectID, in doc: SketchDocument) -> ObjectID        // group id or the object id
  public func bodyMembers(_ body: ObjectID, in doc: SketchDocument) -> [ObjectID]    // group members, or [body]
  /// Edits that make joints and groups consistent with the objects present: anchors on missing objects or wires
  /// dropped; duplicate bodies within one joint collapsed to the first anchor; invalid joints removed; groups
  /// lose missing members and wires, groups with < 2 members removed. Empty when already consistent.
  public func jointIntegrityEdits(in doc: SketchDocument) -> [SceneEdit]
  ```
- `SceneObject`: `.joint(Joint)`; `id`, `withID`, `translated(by:)` (position and every anchor point), `rotated(by:around:)` (same), Codable type tag `"joint"`.
- `bounds(of:)` for a joint: square of side `2 * Joint.radius` centred on `position`. `hitTest`: distance to `position` ≤ `Joint.radius + tolerance`. Lasso: contains `position`.
- `deletionEdits(_:in:)`: after its existing edits, appends the integrity edits computed on the resulting document (one undo step).
- `DocumentPackage`: writes 4, accepts ≤ 4, `groups` absent in older files → `[]`; validation: finite points, anchors non-empty for hinge, exactly one anchor and `grounded` for `fixed`; on read applies `jointIntegrityEdits` (repair, not reject).

- [ ] **Step 1: Write failing tests:**
  - `jointRoundTripsThroughPackage`: document with two shapes, a hinge with two anchors, a grounded hinge, a fixed joint and one group → write, read → equal; JSON has `"formatVersion":4`.
  - `olderVersionsOpen`: a v3 package (no `groups` key) reads with `groups == []`, `formatVersion == 4`.
  - `version5Rejected`.
  - `jointTranslatesAndRotatesWithAnchors`: `translated(by: (3,4))` moves `position` and both anchor points by (3,4); `rotated(by: .pi/2, around: .zero)` maps (10,0) → (0,10) for all of them.
  - `jointBoundsAndHit`: joint at (5,5): bounds == Rect((3.8,3.8), (2.4,2.4)); hit at (5.9,5) tolerance 0 true; at (7,5) false.
  - `bodyIDUsesGroup`: grouped objects share the group id; ungrouped object is its own body.
  - `setGroupsIsUndoable`: `DocumentModel.perform(.setGroups([g]))` → `groups == [g]`, undo → `[]`, registers one undo step even though `objects` did not change.
  - `integrityDropsAnchorsOfMissingObjects`: hinge A–B, object B absent → hinge removed (one anchor, not grounded); grounded hinge A–B with B absent → kept with one anchor; hinge A–B–C with C absent → kept with A, B.
  - `integrityCollapsesSameBodyAnchors`: hinge with anchors on two objects of one group, not grounded → removed.
  - `integrityCleansGroups`: group [a, b, missing] → [a, b]; group [a, missing] → removed; a wire id in a group is dropped.
  - `deletionRemovesPinsInOneUndo`: delete bar B of hinge A–B via `deletionEdits` + `perform` → no joints left; `undo()` once → bar and hinge both back.
  - `corruptJointRejected`: a `fixed` joint with two anchors in a package → `.corrupt`; a joint `position` written as the literal `1e999` → `.corrupt`.
  - `fileRepairOnRead`: package whose hinge references an object id not in `objects` → reads, hinge repaired / removed per the integrity rules.
- [ ] **Step 2: Run** `-only-testing:SketchCoreTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** full package suite → PASS.
- [ ] **Step 5: Commit** `feat(core): joints and groups in the document; file format 4`.

### Task 3: Drawing joints (canvas and export)

**Files:**
- Modify: `Sources/CanvasUI/Rendering/ObjectLayerFactory.swift`, `Sources/CanvasUI/Rendering/SceneRenderer.swift`, `Sources/CanvasUI/Selection/CanvasView+Selection.swift` (`topObject`), `Sources/ExportKit/SceneDrawer.swift`, `Sources/ExportKit/SVGWriter.swift`
- Create: `Sources/SketchCore/Query/JointGeometry.swift`
- Test: `Tests/CanvasUITests/JointRenderingTests.swift`, additions in `Tests/ExportKitTests/SceneDrawerTests.swift`, `Tests/ExportKitTests/SVGTests.swift`

**Interfaces:**
- Consumes: `Joint` (Task 2).
- Produces: `public enum JointGeometry` with the shared mark geometry in mm relative to `position`, used by canvas and both exporters (no duplicated numbers): `ringRadius = 1.2`, `dotRadius = 0.35`, `strokeWidth = 0.3`, `groundMark(at:) -> [[Vec2]]` (polylines: a 3.6 mm wide base line 1.8 mm below the centre plus three hatch strokes), `lockMark(at:) -> [[Vec2]]` (a 2.4 × 1.8 mm box with a shackle arc above, as polylines). Colour: accent blue `RGBAColor(r: 0, g: 0.48, b: 1)`, ring filled white.
- Canvas: joint layers sit above all other object layers regardless of document order, in normal rendering and in move previews. `topObject(at:)` returns a joint when one is hit, before any other object.
- Export: joints drawn last (after all other objects) in `SceneDrawer` and `SVGWriter` (`<g class="joint">`). `ExportContent` bounds include joints (through `bounds(of:)`).

- [ ] **Step 1: Write failing tests:**
  - `jointLayerAboveLaterObjects`: document `[joint, shape]` (shape later in z-order, overlapping): the joint's layer is above the shape's layer in the renderer's sublayer order (or has a higher `zPosition`).
  - `topObjectPrefersJoint`: filled rectangle over a joint at the same point → `topObject(at:)` is the joint.
  - `groundedAndFixedMarksDiffer`: layer paths of a plain hinge, a grounded hinge and a fixed joint at one position are pairwise different; the plain hinge path's bounding box is ≈ 2.4 mm wide (within the stroke width).
  - `SceneDrawerTests`: a hinge at (10,10) renders the accent colour at (10 + 1.2, 10) and white at (10 + 0.8, 10); a filled black rectangle later in z-order covering (10,10) does not hide the dot at (10,10).
  - `SVGTests`: output contains one `<g class="joint">` per joint, after every other object element; grounded hinge group contains more path/line elements than a plain one.
- [ ] **Step 2: Run** `-only-testing:CanvasUITests`, `ExportKitTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** full package suite → PASS.
- [ ] **Step 5: Commit** `feat: draw hinge, ground and lock marks`.

### Task 4: Mechanism extraction and drag session (`MechKit`)

**Files:**
- Create: `Sources/MechKit/Mechanism.swift`, `Sources/MechKit/MechanismDrag.swift`
- Test: `Tests/MechKitTests/MechanismTests.swift`

**Interfaces:**
- Consumes: Task 1 solver; Task 2 `Joint`, `bodyID`, `bodyMembers`; SketchCore `carriedParts(by:in:)`, `reconcileWires(in:)`, `SceneObject.rotated(by:around:)`, `translated(by:)`.
- Produces:
  ```swift
  public struct Mechanism: Sendable {
      /// Connected set of bodies reachable from `object` through joints; nil when its body has no joint.
      public init?(containing object: ObjectID, in doc: SketchDocument)
      public var bodies: [ObjectID]                 // body ids, stable order (document order of first member)
      public var joints: [ObjectID]
      /// Every object that moves with the mechanism: body members plus carried plugged parts.
      public var objectIDs: Set<ObjectID>
      public func members(of body: ObjectID) -> Set<ObjectID>   // incl. carried parts
      public var hasGroundOrLock: Bool
  }
  /// True when `ids` holds every object and every joint of each mechanism it touches (then it moves freely as one piece).
  public func selectionCoversWholeMechanisms(_ ids: Set<ObjectID>, in doc: SketchDocument) -> Bool
  /// True when rotating / free-moving `ids` would break a pin: a joint has an anchor inside and an anchor outside
  /// `ids`, or a grounded / fixed joint has an anchor inside `ids` while the joint itself is not in `ids`.
  public func selectionIsPinnedToOutside(_ ids: Set<ObjectID>, in doc: SketchDocument) -> Bool
  public final class MechanismDrag {
      /// nil when `object`'s body has no joint.
      public init?(grabbing object: ObjectID, at world: Vec2, in doc: SketchDocument)
      /// Replacement objects for the finger at `world`: moved body members, carried parts, joints with updated
      /// anchor points and positions, and re-synced wires. Keeps the previous result when the solve fails.
      public func move(to world: Vec2) -> [SceneObject]
      public var replacements: [SceneObject] { get }   // last result
  }
  ```
- Rules: body pose origin = centroid of the body's anchor points at drag start. A `fixed` joint and bodies locked by it → `isFixed`. Grounded hinge → constraint to its `position`. An n-anchor hinge → n−1 constraints (each anchor to the first). Applying a pose to a body: every member object `rotated(by: angle, around: origin).translated(by: translation)` from its **drag-start** value (no accumulation across frames); its anchor copies get the same transform; each joint's `position` = its first anchor's point (grounded: unchanged). A wire with both ends attached to parts of one body gets its bends transformed with that body; all wires re-synced at the end.

- [ ] **Step 1: Write failing tests** (scenes built from line shapes as bars; helper builds the four-bar of Task 1 as a document: ground hinges at A and D, bars AB, BC, DC as `.line` shapes, hinges at B and C):
  - `mechanismFindsConnectedBodies`: from bar BC → 3 bodies, 4 joints; an unrelated shape is not included; `Mechanism(containing: unrelated)` is nil.
  - `groupIsOneBody`: bar BC grouped with a text label → `members(of:)` contains both; label moves rigidly with the bar in a drag.
  - `dragMovesBarsAndKeepsPins`: grab bar AB at B, move to crank angle −60°: replacements contain 3 shapes + 4 joints; every joint's anchors coincide within 1e-6; bar lengths (|start − end|) unchanged within 1e-9; ground hinge positions unchanged.
  - `noAccumulationOverManyFrames`: 500 frames sweeping the crank −90° ↔ 0° and back to the start: bar lengths unchanged within 1e-9; final shapes within 1e-4 of the originals.
  - `doesNotFlipAssembly`: sweeping through crank angles never changes the sign of the cross product (C − B) × (D − B) relative to the start.
  - `lockedBodyStays`: fixed joint on the coupler: `move` returns no changed shapes (rigid).
  - `carriedPartsRide`: body = breadboard part (pinned to ground by a hinge) with a plugged module and a wire attached to the module: after a drag, `contacts(in:)` and wire attachments equal the start, the wire's attached end is on its connector.
  - `selectionCoversWholeMechanisms` / `selectionIsPinnedToOutside`: whole four-bar incl. joints → covers = true, pinned = false; bars only without joints → covers = false, pinned = true (grounded joints not selected); a loose shape alone → covers = true, pinned = false.
  - `failedSolveKeepsPreviousResult`: inject an impossible state (anchors of one hinge 50 mm apart on two locked bodies) → `move` returns the previous replacements, no NaN.
- [ ] **Step 2: Run** `-only-testing:MechKitTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** full package suite → PASS.
- [ ] **Step 5: Commit** `feat(mech): mechanism extraction and drag session`.

### Task 5: Pin tool, Lock in place, Group / Ungroup

**Files:**
- Modify: `Packages/FlyingSketchKit/Package.swift` (`CanvasUI` depends on `MechKit`), `Sources/CanvasUI/Tools/Tool.swift` (`ToolKind.pin`), `Sources/CanvasUI/CanvasView.swift` (`Interaction.pin(start:)`, routing, switches), `Sources/CanvasUI/Selection/CanvasView+Selection.swift` (edit menu items; tap / lasso selection expands to whole groups), `App/Views/ToolPalette.swift` (Pin button, SF Symbol `pin`)
- Create: `Sources/SketchCore/Connectivity/JointBuilders.swift`, `Sources/CanvasUI/Tools/CanvasView+Joints.swift`
- Test: `Tests/SketchCoreTests/JointBuilderTests.swift`, `Tests/CanvasUITests/JointToolTests.swift`

**Interfaces:**
- Consumes: Task 2 model + `jointIntegrityEdits`; Task 3 `topObject` joint preference.
- Produces (SketchCore, pure; each returns edits for ONE undo step, `[]` when nothing to do):
  ```swift
  /// `under`: non-wire, non-joint objects hit at `point`, bottom to top. Joins their bodies on one hinge at
  /// `point`; exactly one body -> grounded hinge; none -> [].
  public func pinEdits(at point: Vec2, under objects: [ObjectID], in doc: SketchDocument) -> [SceneEdit]
  public func toggleGroundEdits(joint: ObjectID, in doc: SketchDocument) -> [SceneEdit]   // ungrounding a 1-anchor hinge removes it
  /// Adds a `fixed` joint at the body's bounds centre, or removes the body's fixed joint when it has one.
  public func toggleLockEdits(object: ObjectID, in doc: SketchDocument) -> [SceneEdit]
  public func groupEdits(_ ids: Set<ObjectID>, in doc: SketchDocument) -> [SceneEdit]     // merges existing groups; wires and joints ignored; < 2 objects -> []
  /// `objectsAt`: former members hit at a point, bottom to top (the canvas supplies hit-testing).
  public func ungroupEdits(group: ObjectID, objectsAt: (Vec2) -> [ObjectID], in doc: SketchDocument) -> [SceneEdit]
  ```
- Canvas: `public func groupSelection()`, `ungroupSelection()`, `toggleLockSelection()`; `var selectionCanGroup / canUngroup / canLock: Bool`; edit menu items "Group", "Ungroup", "Lock in Place" / "Unlock" shown per those flags. Pin tool: a touch that travels ≤ 4 pt and lifts = tap at its start point (snapped to grid when `snapsToGrid`); tap on a joint → `toggleGroundEdits`; else `pinEdits` with the objects hit there (tolerance `hitSlop`). Action names: "Add Pin", "Pin to Background" / "Release Pin", "Lock in Place" / "Unlock", "Group", "Ungroup".
- Selection: tapping or lassoing any member of a group selects all its members.

- [ ] **Step 1: Write failing tests:**
  - Builders: `pinJoinsAllBodiesUnderPoint` (three overlapping shapes → one hinge, 3 anchors at the point, not grounded); `pinSingleObjectGrounds`; `pinNothingIsEmpty`; `pinSameBodyTwiceCountsOnce` (two objects of one group → grounded hinge with one anchor); `pinIgnoresWires`; `toggleGround` (2-anchor hinge: grounded flips both ways; grounded 1-anchor hinge → removed); `toggleLockAddsThenRemoves` (fixed joint at bounds centre, one anchor, grounded); `groupMergesBodiesAndDropsInnerHinges` (bars A, B hinged, group both → one group, hinge removed; a grounded hinge A–B stays grounded with one anchor); `groupNeedsTwoObjects`; `ungroupReattachesPins` (group [a, b] with a hinge anchored on `a` to outside bar c at a point lying on `b` only → anchor object becomes `b`; point with no former member → anchor dropped, integrity removes the hinge).
  - Canvas: `pinToolTapCreatesHinge` (two overlapping filled rectangles, pin tool, `route` gives `.pin`, simulated tap → document has one hinge; undo removes it); `pinToolTapOnPinTogglesGround`; `pinToolSnapsToGrid`; `groupSelectsTogether` (group two strokes, tap one → both selected); `menuFlags` (`selectionCanGroup` true for two loose objects, `canUngroup` true for a grouped selection, `canLock` true for a single body).
- [ ] **Step 2: Run** `-only-testing:SketchCoreTests`, `CanvasUITests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** full package suite → PASS; app build `cd ~/coding_projects/FlyingSketch && xcodegen && xcodebuild -scheme FlyingSketch -destination 'id=08D1B7B4-263D-4479-8F34-C24730978306' build` → `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit** `feat: pin tool, lock in place, group and ungroup`.

### Task 6: Mechanism drag, pin drag and selection rules on the canvas

**Files:**
- Create: `Sources/CanvasUI/Selection/CanvasView+Mechanism.swift`
- Modify: `Sources/CanvasUI/CanvasView.swift` (`Interaction.mechanism`, `.pinMove`; routing; switches; `allowsUndoTap`), `Sources/CanvasUI/Selection/CanvasView+Selection.swift` (`route` / `beginMove` decision, `documentChanged` cancel, `movedObjects` / free move includes joints for whole mechanisms), `Sources/CanvasUI/Selection/CanvasView+Rotation.swift` (`rotateHandleCenter` nil when pinned to outside), `Sources/CanvasUI/Parts/CanvasView+Parts.swift` (`rotateSelectedParts` no-op when pinned to outside; menu hides the items)
- Test: `Tests/CanvasUITests/MechanismCanvasTests.swift`

**Interfaces:**
- Consumes: Task 4 `MechanismDrag`, `selectionCoversWholeMechanisms`, `selectionIsPinnedToOutside`; Task 3 `topObject`.
- Produces on `CanvasView`: `var mechanismDrag: MechanismDrag?`; `beginMechanismDrag(object:at:)`, `moveMechanism(to:)`, `endMechanismDrag()`, `cancelMechanismDrag()`; `beginPinMove(_:at:)`, `movePin(to:)`, `endPinMove(at:)`, `cancelPinMove()`.
- Routing (selection mode, after leg / wire-handle / rotate-handle checks):
  1. touch on a **selected** joint → `.pinMove`;
  2. touch inside the selection, selection covers whole mechanisms (or has no pinned object) → existing `.move` (joints translate with it);
  3. touch inside the selection on an object whose body has a joint → `.mechanism` grabbing that object at the touch point;
  4. otherwise existing behaviour. A touch inside the selection that hits only loose objects of a partially pinned selection → `.move` of the loose objects only (pinned ones stay).
- Mechanism drag: live preview through `renderer.setMovePreview(ids: [], offset: .zero, replacing:)`; selection box and handles hidden during the drag; release commits `.replace(replacements)` as "Move Mechanism" (no edit when nothing changed or travel < 4 pt); no plug snap; cancel paths (second finger, Pencil takeover, window gone, outside undo) → no edit, preview cleared.
- Pin move: the joint's `position` and every anchor `point` are set to the new spot (bodies do not move), snapped to grid when `snapsToGrid`; "Move Pin"; tap (travel < 4 pt) → no edit.

- [ ] **Step 1: Write failing tests** (four-bar document from Task 4's helper; lasso tool):
  - `routeMechanismDragOnPinnedBar`: bar AB selected → `route` at its midpoint is `.mechanism`; an unpinned shape selected → `.move`.
  - `routeWholeMechanismMovesFreely`: all bars and joints selected → `.move`; after a (10,5) move every shape, joint position and anchor moved by (10,5); one undo.
  - `mechanismDragEndToEnd`: begin at B, move to crank angle −45°, end → document bars moved, pins coincide (1e-6), bar lengths unchanged (1e-9), `undoActionName == "Move Mechanism"`, undo restores the original document exactly.
  - `mechanismDragTapMakesNoEdit`; `mechanismDragCancelNoEdit` (via `cancelInteraction()`); `outsideUndoCancelsMechanismDrag`.
  - `pinMoveRelocatesAnchors`: hinge B selected, drag by (3,0) → joint position and both anchor points at B + (3,0), shapes unchanged, "Move Pin".
  - `rotateHandleHiddenWhenPinned`: bar AB selected → `rotateHandleCenter == nil`; all bars selected but not the joints → nil; whole four-bar including all joints selected → non-nil, and a 90° rotate with the handle turns bars, joint positions and anchors together (pins still coincide).
  - `quarterTurnDisabledWhenPinned`: a part pinned to another object, selected alone → `rotateSelectedParts(clockwise: true)` makes no edit.
  - `looseObjectsInPartialSelectionStay`: bar AB and an unrelated stroke selected, mechanism drag on AB → stroke unchanged.
  - `undoTapBlockedDuringMechanismAndPinMove`.
- [ ] **Step 2: Run** `-only-testing:CanvasUITests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** full package suite → PASS; app build → `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit** `feat(canvas): drag mechanisms and pins`.

### Task 7: Clipboard, duplicate, erase with joints and groups

**Files:**
- Modify: `Sources/CanvasUI/Parts/CanvasView+Parts.swift` (`cloned`), `Sources/CanvasUI/Selection/Clipboard.swift`, `Sources/CanvasUI/Selection/CanvasView+Selection.swift` (duplicate / copy / paste / delete), `Sources/CanvasUI/Tools/EraserController.swift`
- Test: `Tests/CanvasUITests/JointClipboardTests.swift`

**Interfaces:**
- Consumes: Task 2 model, `jointIntegrityEdits`, `deletionEdits`.
- Produces: `cloned(...)` (and the clipboard payload) carry joints and groups: object ids remapped in anchors and group members; a joint with any anchor outside the copied set is not copied; a group is copied only when all its members are; copied grounded / fixed joints keep their kind and move by the paste / duplicate offset. Clipboard payload gains `groups` (absent in older payloads → `[]`). Eraser: erasing an object runs through `deletionEdits` (pins cleaned in the same undo step); a joint itself is erasable.

- [ ] **Step 1: Write failing tests:**
  - `duplicateCopiesWholeMechanism`: four-bar with everything selected → duplicate: document has 6 shapes, 8 joints; the copies' anchors reference the copied shapes only; copies offset by `duplicateOffset`.
  - `duplicateDropsPinsToOutside`: only bars AB and BC and hinge B selected → copy has the two bars and hinge B, no hinge to the uncopied rocker, no grounded hinge A (not selected).
  - `copyPasteKeepsGroups`: grouped pair copied and pasted → a new group with the two new ids; original group untouched.
  - `olderClipboardPayloadDecodes`: payload JSON without `groups` → pastes.
  - `eraseBarCleansPins`: eraser over the coupler → coupler and hinges B, C gone in one undo step; undo restores all three.
  - `eraseJoint`: eraser over hinge C → only the hinge removed.
  - `deleteSelectionWithJoint`: joint selected alone, `deleteSelection()` → joint removed, shapes stay.
- [ ] **Step 2: Run** `-only-testing:CanvasUITests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** full package suite → PASS; app build → `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit** `feat(canvas): copy, duplicate and erase with joints and groups`.
