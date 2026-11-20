# Mechanical joints — design

Status: draft for Lars' approval. Follows the "Future: mechanical joints" line of the v1 design (`2026-11-18-flyingsketch-v1-design.md`).

## Intent

Lars wants to design linkages and robot assemblies on the canvas: multilink hinges, arms, grippers. He sketches bars and parts, pins them together, drags one and watches the rest move, to find the assembly that gives a wanted motion. It is a kinematics sketch tool: positions and angles only.

## Goals

1. Any canvas object can be a moving body: ink, shapes, images, text, parts. Several objects can be grouped into one rigid body.
2. Hinge pins join two bodies, or one body to the background.
3. Dragging a pinned body moves the whole mechanism live, pins holding exactly.
4. Every object can sit at any angle; a selection can be rotated freely.
5. Later (plan 3): slide and pin-in-slot joints, tracing a point's path, angle readouts.

## Non-goals

Forces, masses, gravity, collisions, friction. 3D. Gears, belts, cams, springs. Angle limits and motors (candidates after plan 3). Animation playback / recording. A separate motion mode.

## Anti-goals

- Pins that visibly stretch or bars that change length while dragging.
- A drag that scrambles the drawing with no single undo to get back.
- Electrical behaviour (wires, nets, plugging) changing because of joints.
- Old documents failing to open or looking different.

## Approaches

**Rotation**
- A (picked): each object stores its own angle. Rectangles, ellipses, text, images, parts get a rotation; ink, lines, arrows and wires have their points rotated. Flat model, each object self-contained.
- B: pose layer per body applied at draw time. Free "reset pose", but every geometry reader must apply it; reset is not needed with always-live motion. Rejected.

**Bodies**
- 1 (picked by Lars): pin anything drawn; group to make a rigid body.
- 2: dedicated link tool (bars with holes). Possible later shortcut on top of 1.
- 3: joints only on library part connectors (old spec line). Rejected: needs a part before an idea can be tried.

**Dragging**
- 1 (picked by Lars): always live, no mode. Drag a pinned body = motion. Drag a pin = change the design. Whole mechanism selected = moves as one piece.
- 2: separate motion mode with reset on exit. Rejected: constant mode switching.

**Solver**
- A (picked): exact Newton-style least-squares solver (damped / Levenberg–Marquardt) over body poses, own Swift code, no GPL solvers.
- B: iterative relaxation. Rejected: pins stretch on fast drags.

## Design

### Part 1 — free rotation (plan 1)

- **Model:** `rotation` in radians, clockwise positive (y-down), about the object's centre, on: rectangle and ellipse shapes, text, images, parts. For parts it replaces `quarterTurns`; old files decode `quarterTurns × 90°`. Ink, lines, arrows, wires: no field, points are rotated.
- **Everything that reads geometry honours rotation:** drawing, bounds (axis-aligned box around the rotated object), hit-testing, eraser, lasso, connector positions, leg origins, plugging, net computation, PNG/PDF/SVG export, part thumbnails stay unrotated.
- **Parts at free angles:** plugging and wire attachment stay derived from pin positions as today; they work at any angle when pins coincide. Rotating a part behaves like moving it rigidly (attached wire ends follow, legs as on a rigid move).
- **Rotate handle:** a round knob above the selection box. Drag rotates the selection about the centre of its box; live preview; one undo step "Rotate". With grid snapping on, the angle snaps to 15° steps. The existing 90° rotate action stays.
- **Selection box** stays axis-aligned around the rotated content (my call).
- **Text editing** of rotated text: the editor appears at the text's angle.

### Part 2 — bodies, hinges, motion (plan 2)

- **Body:** a set of objects that move as one, with its own reference frame (origin + angle). Stored in the document, undoable. Created by "Group" on a selection, or automatically (single object) when a pin is dropped on an ungrouped object. "Ungroup" dissolves it; an automatic single-object body disappears with its last pin. Grouped objects select together. An object is in at most one body. Wires cannot be body members (they are flexible); they keep following the parts they attach to.
- **Hinge:** a new canvas object. Names body A and body B, or body A and the background, and stores its spot in each body's frame (background: world mm). Drawn on top of everything: small ring with centre dot; a background pin adds a ground mark. Selectable, deletable, copyable with its bodies.
- **Pin tool (decided by Lars):** new tool. Snaps to the grid when grid snapping is on.
  - Tap a spot with two or more objects under it: all their bodies are joined on one shared pivot there (n bodies, one pivot; objects of the same body count once).
  - Tap a spot with one object under it: that body is pinned to the background.
  - Tap an existing pin: toggles whether that pivot is fixed to the background.
  - Tap empty canvas: nothing.
- **Lock in place (decided by Lars):** action on a selected body that fixes it to the background at its current position and angle (the "fixed" joint of the v1 spec); the same action unlocks. A locked body shows a small lock mark. It is the quick way to make a frame or base plate.
- **Motion (select tool / finger selection):**
  - Drag starts on a body that has pins: mechanism drag. The grabbed point follows the finger as closely as the pins allow; connected bodies move live. One undo step "Move Mechanism".
  - What holds still (decided by Lars): bodies that are not dragged stay where they are as far as the pins allow (least total motion), also when nothing is fixed to the background. Locked bodies never move.
  - A partial selection does not change this: the grabbed body is pulled, pins decide the rest; loose (unpinned) objects in the selection stay put.
  - Plugged parts ride along: parts plugged into a moving part (transitively) move with it as in today's part move; a leg plugged into a part outside the moving set keeps its end and stretches, as today.
  - Whole connected mechanism selected (all bodies and pins): moves as one piece, background pins included.
  - Drag a selected pin: the joint moves to the new spot on both bodies; bodies stay. One undo step "Move Pin". The spot may lie outside the visible shape.
  - Rotate handle (and the 90° action) is hidden unless the selection is free of pins to outside bodies and of locked bodies.
- **Limits:** when the finger asks for an unreachable pose, the mechanism goes as far as it can and stays there. A rigid arrangement (e.g. a triangle, or two background pins on one body) does not move. No error dialogs.
- **Group / Ungroup and pins:** groups are flat. Grouping objects that already belong to bodies merges those bodies into one; hinges between the merged bodies are removed. Ungrouping re-attaches each pin to the topmost former member under its spot (as a single-object body), or deletes the pin when no member is there. All in one undo step.
- **Deleting:** deleting a body's last object deletes its hinges in the same undo step. Copy / duplicate of a selection copies the bodies and the hinges whose bodies are both copied (background pins too); other hinges are dropped from the copy.
- **Solver (own package target, no UI code):**
  - Unknowns: position and angle of every body in the connected mechanism; background fixed.
  - Hard rules: each hinge keeps its two spots together (2 equations).
  - Drag: soft target pulling the grabbed point to the finger; a weak pull keeps every other body near its previous pose (least total motion). Locked bodies are fixed like the background.
  - Each frame starts from the previous pose, so the mechanism stays on its current assembly branch and never flips.
  - Targets: pin error under 0.001 mm after solve; a 50-body mechanism solves within 2 ms per frame on the iPad.
  - Tests against closed-form results: four-bar (crank-rocker) positions, a rigid triangle (no motion), unreachable target (stops at full extension), two separate mechanisms (only the dragged one moves).
- **Electrical side unchanged:** nets, plugging, wires, BOM and netlist are computed as before from the moved geometry. Export draws pins; BOM/netlist ignore them.
- **Files:** format version raised. Older documents open unchanged. Bodies and hinges are saved with the document.

### Part 3 — outline only (plan 3, own short design when we get there)

Slide joint (a body moves along a line on another), pin-in-slot, tracing the path of a chosen point during a drag, angle readout at a hinge.

## Order of work

Three plans, each shippable: (1) free rotation, (2) bodies + hinges + solver + motion, (3) slide, slot, tracing, readouts.

## Left to the builder

- How bodies are stored and edited undoably (document table vs object field), and the exact Swift types.
- Solver internals (damping scheme, iteration cap, drag weight), as long as the targets and tests above hold.
- Handle and pin styling, exact hit radii (follow the existing 12 pt handle pattern).
- How rotated text / images / parts are drawn in Core Animation and in the export drawer.

## My calls (not discussed with Lars)

- Rotation snaps to 15° with grid snapping on; selection box stays axis-aligned.
- Wires cannot join a body.
- Plugged parts ride along with a moving part; partial selections do not change a mechanism drag.
- Grouping merges bodies and removes hinges between them; ungroup re-attaches pins to the member under the spot.
- Text keeps its stored top-left position (old documents unchanged) and rotates about the centre of its box.
- No plug snapping at the end of a mechanism drag.
- Pins always draw on top.
- Unreachable drags stop silently at the limit.
- Rotate handle hidden for partially pinned selections.
- Copy drops hinges whose other body is not copied.
- A pin's spot may lie outside the visible shape.
