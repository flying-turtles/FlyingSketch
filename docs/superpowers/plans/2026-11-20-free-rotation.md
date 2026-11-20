# Free Rotation Implementation Plan (joints step 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every canvas object can sit at any angle, and a selection can be rotated freely with a handle.

**Architecture:** Parts and rectangle/ellipse shapes store a `rotation` (text and images already do); ink, lines, arrows and wires get their points rotated. One pure SketchCore function rotates a set of objects about a pivot (parts carry plugged parts, wires re-sync). A `RotationController` in CanvasUI runs the handle drag and commits one edit.

**Tech Stack:** Swift 6 strict concurrency, UIKit / Core Animation, CoreGraphics export, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-20-mechanical-joints-design.md` (Part 1). Bodies, pins and the solver are later plans; nothing of them here.

## Global Constraints

- Angles: radians, clockwise positive in the y-down world, same convention as `Vec2.rotated(by:)` and the existing `TextObject.rotation` / `ImageObject.rotation`.
- Pivots: part = `center`; rectangle/ellipse = centre of its box; image = frame centre (existing); text = `position` (existing, unchanged).
- Quarter turns stay exact: a rotation within 1e-9 of k·π/2 is stored as exactly k·π/2 and `worldPoint` uses the exact integer path for it (existing equality-based tests and plugging must keep passing).
- Stored rotation is normalised to [0, 2π).
- File format: `formatVersion` 3. Version 2 and 1 documents open unchanged; a part without `rotation` decodes `quarterTurns × π/2`; a shape without `rotation` decodes 0. Writer emits `rotation` only. Version > 3 → `unsupportedVersion`.
- Rotating a part is a rigid move: leg ends rotate with it, parts plugged into it (`carriedParts(by:in:)`) rotate too, attached wire ends follow via the existing wire reconcile.
- The existing 90° action (`rotateSelectedParts`) keeps its behaviour (own centre, legs reset).
- Rotate handle: knob centred 28 pt above the top edge of the selection box, radius 7 pt, hit radius 16 pt; shown in selection mode whenever the selection is non-empty; hidden during move, leg, bend and rotate drags.
- Rotation about the centre of the selection's world bounds. With `snapsToGrid` the angle snaps to multiples of 15°. One edit, action name "Rotate". Release under 4 pt travel (`legMinTravel`) or zero angle = no edit.
- The selection box stays axis-aligned (bounds of rotated content).
- Part thumbnails stay unrotated. BOM / netlist unchanged.
- Package tests: `cd Packages/FlyingSketchKit && xcodebuild test -scheme FlyingSketchKit-Package -destination 'id=08D1B7B4-263D-4479-8F34-C24730978306'`; narrow with `-only-testing:<Target>` (a file-level filter runs 0 free `@Test` functions). `swift test` does not work (UIKit).
- Commits end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## Review Focus

1. A version-2 document with parts at `quarterTurns` 1–3 (some plugged, some wired): opens, looks and nets exactly as before, saves as version 3, reopens equal.
2. A part at a non-quarter angle: hit-testing and lasso follow the rotated body, not its bounding box; eraser and tap-select agree with what is drawn.
3. PNG / PDF / SVG export of rotated parts, rectangles and ellipses matches the canvas (same pivot, same direction).
4. Rotating a breadboard with plugged modules and attached wires: contacts and nets are the same before and after; undo restores everything in one step.
5. Rotate drag interrupted (second finger, Pencil takeover, outside undo): no edit, preview cleared, handle back.

---

### Task 1: Part rotation model, geometry and file format

**Files:**
- Create: `Packages/FlyingSketchKit/Sources/SketchCore/Geometry/Angle.swift`
- Modify: `Sources/SketchCore/Model/PartInstance.swift`, `Sources/SketchCore/Connectivity/PartGeometry.swift` (doc comment), `Sources/SketchCore/Connectivity/PartEdits.swift` (`rotatePart`), `Sources/SketchCore/Query/HitTesting.swift` (part bounds / hit), `Sources/SketchCore/File/DocumentPackage.swift`, `Sources/SketchCore/Model/SketchDocument.swift` (default version 3), `Sources/SketchCore/Fixtures.swift`, `Sources/CanvasUI/Rendering/ObjectLayerFactory.swift:269`, `Sources/ExportKit/SceneDrawer.swift:134`, `Sources/ExportKit/SVGWriter.swift:178`
- Modify tests using `quarterTurns:` on `PartInstance` (ExportKitTests, CanvasUITests, SketchCoreTests, PartsKitTests): `quarterTurns: k` → `rotation: Double(k) * .pi / 2`. PhotoPartKit `Crop.quarterTurns` is unrelated: do not touch.
- Test: `Tests/SketchCoreTests/PartRotationTests.swift`

**Interfaces:**
- Produces:
  - `public func normalizedAngle(_ a: Double) -> Double` — wraps to [0, 2π), snaps to exact k·π/2 within 1e-9 (2π → 0).
  - `public func quarterTurns(of a: Double) -> Int?` — 0...3 when `normalizedAngle(a)` is an exact quarter turn, else nil.
  - `PartInstance.rotation: Double` (replaces `quarterTurns`; init parameter `rotation: Double = 0` in the same position; init and setter callers pass normalised values via `normalizedAngle`).
  - `PartInstance.bodyCorners(in def: PartDefinition) -> [Vec2]` — 4 world corners (local TL, TR, BR, BL). Replaces `bodyRect(in:)` (delete it).
  - `PartInstance.localPoint(_ world: Vec2, in def: PartDefinition) -> Vec2` — inverse of `worldPoint`.
  - `rotatePart(_:clockwise:in:)` unchanged signature; sets `rotation = normalizedAngle(rotation ± π/2)`.

- [ ] **Step 1: Write failing tests** (`PartRotationTests.swift`, `fixtureResistor` / a 20×10 definition with a connector at local (0,0)):
  - `normalizedAngleWrapsAndSnaps`: `normalizedAngle(-.pi/2) == 3 * .pi / 2`; `normalizedAngle(2 * .pi) == 0`; `normalizedAngle(.pi/2 + 1e-12) == .pi/2`; `normalizedAngle(1.0) == 1.0`.
  - `quarterTurnsOfAngle`: `quarterTurns(of: .pi) == 2`; `quarterTurns(of: 1.0) == nil`.
  - `worldPointExactAtQuarterTurns`: part 20×10 centre (100,50), rotation π/2: `worldPoint((0,0)) == (105, 40)` exactly; rotation π: `== (110, 55)`.
  - `worldPointAtFreeAngle`: rotation π/6: `worldPoint((0,0))` within 1e-9 of `center + (-10,-5).rotated(by: .pi/6)`; `localPoint(worldPoint(q)) ≈ q`.
  - `boundsOfRotatedPart`: 20×10 at π/4, no legs: `bounds(of:in:)` width and height both ≈ 30·√½ (21.2132, tolerance 1e-6), centred on `center`.
  - `hitTestFollowsRotatedBody`: same part: point at `center + (9,0).rotated(by: .pi/4)` hits; the bounding-box corner `center + (10,10)` does not (tolerance 0.1).
  - `rotatePartStepsQuarterTurn`: twice clockwise from 0 → `rotation == .pi`; once counter-clockwise from 0 → `3 * .pi / 2`.
  - `legacyQuarterTurnsDecode`: JSON part object with `"quarterTurns": 3` and no `rotation` decodes `rotation == 3 * .pi / 2`; encoding it yields a `rotation` key and no `quarterTurns` key.
  - `version2DocumentOpensAndSavesAs3`: build package data from a v2 `document.json` (take `DocumentPackage`'s writer output, rewrite `formatVersion` to 2 and the part to `quarterTurns: 1`), read → part `rotation == .pi/2`, `formatVersion == 3`; write + read round-trips equal.
  - `version4Rejected`: `formatVersion` 4 → `DocumentError.unsupportedVersion(4)`.
  - `nonFiniteRotationRejected`: part `rotation` NaN → `.corrupt`.
- [ ] **Step 2: Run** `-only-testing:SketchCoreTests` → FAIL (compile: missing members).
- [ ] **Step 3: Implement.** `worldPoint`: `if let q = quarterTurns(of: rotation)` keep the existing exact switch, else `center + rel.rotated(by: rotation)`. Part bounds = bounding box of `bodyCorners` unioned with leg segments as today. Part hit = `localPoint(point)` inside the definition rect inset by `-tolerance`, or a leg. `fallbackPartRect` (no definition) stays a 10 mm square. Canvas factory: `CATransform3DMakeRotation(p.rotation, 0, 0, 1)`. `SceneDrawer`: `ctx.rotate(by: p.rotation)`. `SVGWriter`: emit `rotate(<degrees>)` from `p.rotation` (keep the no-transform fast path at 0). Custom `Codable` for `PartInstance` per Global Constraints. `DocumentPackage`: write 3, accept ≤ 3, validate `rotation.isFinite`.
- [ ] **Step 4: Run** full package suite → PASS.
- [ ] **Step 5: Commit** `feat(core): parts rotate freely; file format 3`.

### Task 2: Rotated rectangles and ellipses

**Files:**
- Modify: `Sources/SketchCore/Model/ShapeObject.swift`, `Sources/SketchCore/Query/SceneGeometry.swift`, `Sources/SketchCore/Query/HitTesting.swift`, `Sources/SketchCore/File/DocumentPackage.swift` (validation), `Sources/CanvasUI/Rendering/ObjectLayerFactory.swift` (`updateShape`), `Sources/ExportKit/SceneDrawer.swift:53`, `Sources/ExportKit/SVGWriter.swift:133`
- Test: `Tests/SketchCoreTests/ShapeRotationTests.swift`, additions in `Tests/ExportKitTests/SceneDrawerTests.swift`, `Tests/ExportKitTests/SVGTests.swift`, `Tests/CanvasUITests/ShapeControllerTests.swift`

**Interfaces:**
- Consumes: `normalizedAngle` (Task 1).
- Produces:
  - `ShapeObject.rotation: Double` (last stored property; init parameter `rotation: Double = 0` last; decodes 0 when absent). Meaningful for `.rectangle` / `.ellipse`; always 0 for `.line` / `.arrow`.
  - `ShapeGeometry.center(of: ShapeObject) -> Vec2` (box centre) and `ShapeGeometry.corners(of: ShapeObject) -> [Vec2]` (4 world corners of the rotated box).

- [ ] **Step 1: Write failing tests:**
  - `shapeDecodesWithoutRotation`: JSON shape without `rotation` → `rotation == 0`.
  - `rotatedRectBounds`: rectangle (0,0)–(20,10), lineWidth 0, rotation π/2 → `bounds(of:) == Rect(origin: (5,-5), size: (10,20))` within 1e-9.
  - `rotatedRectHitTest`: same, unfilled, tolerance 0.5: point (5,0) (on the rotated box's left edge, x = 5) hits; point (0,5) (old left edge) misses. Filled: (10,-4) hits.
  - `rotatedEllipseHitTest`: filled ellipse (0,0)–(20,10) at π/2: (10,-4) hits, (1,5) misses.
  - `lineIgnoresRotationField`: a `.line` with `rotation: 1` has the same bounds and hit result as with 0.
  - Export (`SceneDrawerTests`): a filled red rectangle (0,0)–(20,4) at π/2 renders red at world (10,-7) and not at (2,2) (use the suite's existing pixel-probe helper).
  - SVG (`SVGTests`): the same shape's element carries `transform="rotate(90 10 2)"`; a shape at 0 has no `transform`.
  - Canvas (`ShapeControllerTests`): the factory layer for that rectangle has a path whose bounding box, converted to world mm, is ≈ (8,-8)–(12,12) (tolerance 0.01).
  - `nonFiniteShapeRotationRejected`: package with shape `rotation` infinity → `.corrupt`.
- [ ] **Step 2: Run** `-only-testing:SketchCoreTests`, then `ExportKitTests`, `CanvasUITests` → FAIL.
- [ ] **Step 3: Implement.** Bounds = bounding box of `corners(of:)` inset by `-lineWidth/2`. Hit test: rotate the point by `-rotation` about the centre, then the existing rectangle / ellipse logic. Canvas: build the path from the rotated geometry (path transform about the box centre), no layer transform. `SceneDrawer` / `SVGWriter`: rotate about the centre.
- [ ] **Step 4: Run** full package suite → PASS.
- [ ] **Step 5: Commit** `feat: rectangles and ellipses rotate`.

### Task 3: Rotate a set of objects about a pivot

**Files:**
- Modify: `Sources/SketchCore/Model/SceneObject.swift`, `Sources/SketchCore/Connectivity/PartEdits.swift`
- Test: `Tests/SketchCoreTests/RotateObjectsTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2 fields, `carriedParts(by:in:)`, the private wire reconcile in `PartEdits.swift`.
- Produces:
  - `SceneObject.rotated(by angle: Double, around pivot: Vec2) -> SceneObject` — ink: every point; line/arrow: `start`, `end`; rectangle/ellipse: box centre moves, size kept, `rotation += angle`; text: `position` rotated, `rotation += angle`; image: frame centre rotated, size kept, `rotation += angle`; part: `center` rotated, `rotation += angle`, every `legEnds` value rotated; wire: both end positions and all bends rotated. Stored rotations pass through `normalizedAngle`.
  - `public func rotateObjects(_ ids: Set<ObjectID>, by angle: Double, around pivot: Vec2, in doc: SketchDocument) -> [SceneObject]` — returns replacements for: every object in `ids`, every part in `carriedParts(by: ids ∩ parts, in: doc)`, and every wire whose attached end moved (re-synced to its connector; an attached end of a wire in `ids` ends at its connector, not at the rotated point). Unchanged objects are not returned. `angle == 0` → `[]`.

- [ ] **Step 1: Write failing tests:**
  - `rotatedInkAndLine`: ink point (10,0) and line (0,0)–(10,0) by π/2 about origin → (0,10) within 1e-9.
  - `rotatedRectKeepsSize`: rectangle (0,0)–(20,10) by π/2 about (0,0): centre ≈ (-5,10), `abs(end - start)` still (20,10), `rotation == .pi/2`.
  - `rotatedTextAndImage`: text at (10,0) rotation 0.2 by 0.3 about origin: position ≈ (10,0).rotated(0.3), rotation ≈ 0.5; image frame (0,0,10,10) by π about (0,0): frame origin ≈ (-10,-10), rotation == π.
  - `rotatedPartMovesLegEnds`: resistor with `legEnds["a"] = (−20,10)` by π/2 about its centre: `legEnds["a"]` ≈ centre + ((−20,10) − centre).rotated(π/2).
  - `fullTurnIsIdentityForQuarterSteps`: any fixture object rotated four times by π/2 about a pivot equals the original within 1e-9 (parts: `rotation == 0` exactly).
  - `rotateObjectsCarriesPluggedParts`: `Fixtures` scene with a module plugged into a breadboard: `rotateObjects([board.id], by: .pi/2, around: board.center, in: doc)` contains the module; applying it leaves `contacts(in:)` equal to before.
  - `rotateObjectsResyncsAttachedWires`: wire attached to a rotated part and not in `ids` is returned with its attached end at the new connector position and bends unchanged; a wire in `ids` has bends rotated and its attached end on the connector.
  - `attachmentsUnchangedByRotation`: for that scene, `contacts(in:)` and every wire's `start.attachment` / `end.attachment` are equal before and after (this is what nets are computed from).
  - `zeroAngleNoChanges`: returns `[]`.
- [ ] **Step 2: Run** `-only-testing:SketchCoreTests` → FAIL.
- [ ] **Step 3: Implement** both functions.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): rotate objects about a pivot`.

### Task 4: Rotate handle on the selection

**Files:**
- Create: `Sources/CanvasUI/Selection/RotationController.swift`, `Sources/CanvasUI/Selection/CanvasView+Rotation.swift`
- Modify: `Sources/CanvasUI/CanvasView.swift` (property, layer, `Interaction.rotate`, `route`, begin/moved/ended/cancel switches, `allowsUndoTap`), `Sources/CanvasUI/Selection/CanvasView+Selection.swift` (`updateSelectionOverlay` calls `updateRotateHandle()`; `documentChanged` cancels a rotate drag), `Sources/CanvasUI/Tools/CanvasView+Creation.swift` (`layoutTextEditor`: editor at the text's angle about its top-left)
- Test: `Tests/CanvasUITests/RotationTests.swift`, addition in `Tests/CanvasUITests/TextEditingTests.swift`

**Interfaces:**
- Consumes: `rotateObjects` (Task 3), `selectionWorldBounds`, `renderer.setMovePreview(ids:offset:replacing:)`, `legMinTravel`, `snapsToGrid`.
- Produces:
  ```swift
  final class RotationController {
      init(model: DocumentModel)
      var minDistance: Double            // tap threshold, mm
      var snapsAngle: Bool               // 15° steps
      var isActive: Bool { get }
      func begin(ids: Set<ObjectID>, pivot: Vec2, grabAt world: Vec2)
      /// Replacement objects for the current angle; [] when inactive.
      func move(to world: Vec2) -> [SceneObject]
      /// Current angle (radians, after snapping); 0 when inactive.
      var angle: Double { get }
      @discardableResult func end(at world: Vec2) -> Bool   // one "Rotate" edit; false when none
      func cancel()
      @discardableResult func documentDidChange(_ doc: SketchDocument) -> Bool  // cancels when any object in `ids` changed
  }
  ```
  Angle = signed angle from (grab − pivot) to (touch − pivot), clockwise positive; snapped with `(angle / (π/12)).rounded() * π/12` when `snapsAngle`. Travel tracked as in `WireBendController` (max distance from grab; under `minDistance` = tap, no edit).
- On `CanvasView`: `Interaction.rotate`; `private(set) var rotation: RotationController!`; `let rotateHandle: CAShapeLayer`; `var rotatePreview: [SceneObject]`; `var rotateHandleCenter: CGPoint?` (view space, nil when hidden); `func rotateHandleHit(at p: CGPoint) -> Bool`; `updateRotateHandle()`, `beginRotate(at:)`, `moveRotate(to:)`, `endRotate(at:)`, `cancelRotate()`.
- `route`: after the leg and wire-handle checks: `if selecting, rotateHandleHit(at: p) { return .rotate }`.
- During a rotate drag the selection box and all handles are hidden; they return on release / cancel.

- [ ] **Step 1: Write failing tests** (`RotationTests.swift`; canvas 1024×1366, lasso tool, one ink stroke (0,0)–(20,0) selected unless noted):
  - Controller: `rotatesByDragAngle` — pivot (0,0), grab (10,0), end (0,10) → stroke end point ≈ (0,20), `undoActionName == "Rotate"`, undo restores. `snapsTo15Degrees` — `snapsAngle`, end at angle 20° → `angle == π/12` (within 1e-12). `tapMakesNoEdit`. `dragAwayAndBackToZeroNoEdit` — angle returns to 0 → no undo entry. `cancelNoEdit`. `documentChangeCancels`.
  - `handleShownAboveSelection`: `rotateHandleCenter` ≈ (selection view rect midX, minY − 28); nil with empty selection.
  - `routeHitsRotateHandle`: `route(isPencil: true, at: handle centre)` is `.rotate`; with the wire tool it is not; finger in Pencil-only mode is `.rotate`.
  - `rotateDragEndToEnd`: `beginRotate` at the handle, `moveRotate` to a point 90° clockwise about the selection centre → `rotatePreview` non-empty and `rotateHandleCenter == nil`; `endRotate` → document stroke rotated ≈ 90° about the centre of its old bounds; `rotatePreview.isEmpty`; handle back.
  - `rotatePartCarriesPluggedAndWires`: `Fixtures` breadboard + plugged module + attached wire, board selected: after a 90° rotate, `contacts(in:)` equal to before and the wire's attached end sits on its connector.
  - `outsideUndoCancelsRotate`: perform an edit, begin + move a rotate, `model.undoManager.undo()` → `!rotation.isActive`, `rotatePreview.isEmpty`.
  - `undoTapBlockedDuringRotate`: `allowsUndoTap(during: .rotate) == false`.
  - `TextEditingTests`: editing a text with `rotation: .pi/2` gives an editor whose `transform` rotation is π/2 (atan2 of `transform.b`, `transform.a`) and whose top-left maps to the text's `position`.
- [ ] **Step 2: Run** `-only-testing:CanvasUITests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** full package suite → PASS.
- [ ] **Step 5: Build app** `cd ~/coding_projects/FlyingSketch && xcodegen && xcodebuild -scheme FlyingSketch -destination 'id=08D1B7B4-263D-4479-8F34-C24730978306' build` → `** BUILD SUCCEEDED **`.
- [ ] **Step 6: Commit** `feat(canvas): rotate handle on the selection`.
