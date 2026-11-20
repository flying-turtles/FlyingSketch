# Wire bend editing — short design

**Intent:** reroute existing wires after drawing: move, add and remove bend points. Today bends are fixed once a wire is committed (only ends can be dragged, in the wire tool).

**Goals:** drag a bend; add a bend on any segment; remove a bend. Each one undo step.
**Non-goals:** editing bends in the wire tool; moving several bends at once; auto-routing / orthogonal routing; smoothing.
**Anti-goals:** handles that hijack normal selection moves; accidental edits from a plain tap on the wire.

## Approaches

1. **Handles on a selected wire (picked by Lars).** Selection mode (lasso tool, or finger with Pencil-only on) shows handles on every selected wire, like leg handles on a selected part. Matches the existing leg-handle pattern; discoverable.
2. Wire-tool gestures (drag bend, tap segment to add, double-tap to remove). Rejected: competes with the wire tool's tap-to-draw/continue.

## Design

- **Handles** (selected wires only):
  - Bend handle: filled accent circle at each bend, same look and hit radius as leg handles (`legHandleRadius`: ≥1 mm, ≥12 pt).
  - Insert handle: small hollow accent circle with "+" at each segment midpoint (start → bend → … → end). Hidden when the segment is shorter on screen than 3 × handle diameter, so it never overlaps a bend handle.
- **Routing:** in selection mode, touch-down priority: leg end, bend handle, insert handle, then the normal move / lasso / tap. A touch inside the selection but off any handle still moves the selection.
- **Drag bend:** bend follows the touch by grab offset (no jump); snaps to the 10 mm grid when `snapsToGrid`. Live preview through the renderer move preview; handles follow. Release commits "Move Wire Bend". Release under 4 pt travel = tap.
- **Tap bend:** removes it. Edit "Remove Wire Bend".
- **Drag insert handle:** inserts a bend into that segment and drags it. Release commits "Add Wire Bend". Tap on an insert handle = no edit (my call: avoids stray bends).
- **Ends untouched:** attachments and end positions never change in these edits; nets unaffected.
- **Cancel** (second finger, Pencil takeover, undo from outside): no edit, preview cleared.

## Builder's calls

- Pure geometry helpers on `Wire` in SketchCore (move / insert / remove bend, segment midpoints) plus a `WireBendController` in CanvasUI, mirroring `LegController`.
- Handle layer styling details, exact insert-handle size.
