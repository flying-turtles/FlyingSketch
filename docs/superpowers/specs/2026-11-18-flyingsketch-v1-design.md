# FlyingSketch v1 — Design

Date: 2026-11-18
Status: approved scope, pending builder review

## Intent

Lars does electrical and mechanical engineering, welding, milling, woodwork, drones, robotics and microcontroller tinkering. Existing tools split his work across apps: Concepts (freehand canvas), Fritzing / Cirkit Designer (breadboard wiring, no iPad), Shapr3D / Onshape (CAD). None combines a natural Pencil canvas with parts that *know* their connection points.

FlyingSketch is a native iPad app: an infinite canvas where freehand ink lives next to smart parts. Parts have typed connection points; wires stay attached when parts move; the app knows which pins are connected. Later, the same anchor idea extends to mechanical joints with live 2D motion.

Built for Lars first. Open source on GitHub. App Store maybe later.

## Goals (v1)

First real use: the wiring diagram for an ESP32 project with a few resistors and sensors, on a breadboard and/or free-floating.

1. Infinite canvas: pan, zoom, Pencil ink, basic shapes, text.
2. Parts from a bundled Fritzing-derived catalog (minimum: ESP32 dev boards, breadboards, resistors, common sensors) plus import of `.fzpz` files.
3. Photo parts: photo → automatic cutout → Pencil refinement or full manual tracing → scale calibration → pin placement → personal library.
4. Wires pin-to-pin, free-floating or mixed with breadboard plugging.
5. Live nets computed from wires, plugged contacts and internal part connections.
6. Undo/redo, document files in iCloud Drive / Files.
7. Export: PNG, PDF, SVG, BOM (CSV), netlist (CSV).

## Non-goals (v1)

- Mechanical joints and constraint solver (v2; see "Future").
- Schematic view, PCB layout, simulation.
- DXF import/export.
- Mac version (keep code portable; don't ship it).
- App Store polish: onboarding, monetization, accessibility audit beyond basics.
- Collaboration, sync server, accounts.
- Textured/painterly brushes.

## Anti-goals

- Ink that feels worse than PencilKit. Writing feel is the bar.
- Two disconnected worlds (ink vs parts) with separate undo/selection/export.
- Wires that look attached but aren't in the data, or nets that are wrong.
- Any GPL dependency (blocks App Store later).
- Cloud dependency or account needed to use the app.

## Constraints

- Native Swift + SwiftUI shell, UIKit where needed (canvas, touches). Swift 6, strict concurrency.
- Minimum iPadOS 26. Lars' device: iPad Pro 12.9" 4th gen (iPad8,11, A12Z, ProMotion, Pencil 2). Performance must hold there.
- Xcode 27. Metal toolchain not installed → no `.metal` files in build; compile shaders from source at runtime if Metal is ever used.
- Project generation: xcodegen (`project.yml`), as in the spike.
- Signing: team `WDJPX25GFC`, bundle prefix `com.flyingturtle`.
- Licensing: app code MIT (my call; Lars said open source, license not explicitly chosen). Fritzing parts are CC-BY-SA 3.0: ship as separate assets with attribution; modified parts stay CC-BY-SA.

## Approaches considered

| | Approach | Trade-off | Verdict |
|---|---|---|---|
| A | PencilKit for ink + custom layer for parts/wires | Best ink for free; but ink can't interleave with parts in z-order, zoom sync between two systems, split selection/undo/export | Rejected |
| B | Own scene model, Metal renderer | Unified model, fastest zoom; big upfront GPU path rendering work | Rejected for now |
| **C** | **Own scene model, Core Animation / Core Graphics renderer behind a renderer interface** | Unified model, Apple 2D stack, Metal swap possible later | **Chosen** |

**Ink spike result** (`spikes/InkSpike`, tested on Lars' iPad): PencilKit vs own engine with Core Animation live stroke vs own engine with Metal live stroke. With One-Euro smoothing on (min cutoff 2 Hz) own ink was clearly worse — sharp bends (e.g. an "S") came out rounded. With smoothing **off**, all three felt roughly equal. Consequences:

- Own ink engine is viable. Reuse spike code (`StrokeBuilder`, `StrokeGeometry`, coalesced + predicted touches, pressure curve) as starting point.
- Smoothing default: off. May offer optional light smoothing later.
- Live stroke rendered with Core Animation (`CAShapeLayer`). Metal not needed.

## Design

### Architecture

Swift packages inside one repo, app target thin:

- **SketchCore** — document/scene model, geometry, units, commands (undo). Pure Swift, no UIKit. Unit-tested.
- **InkEngine** — touch samples → stroke points → outline geometry. From spike.
- **PartsKit** — part model, Fritzing `.fzp`/`.fzpz` parser and writer, parts library (bundled + personal).
- **NetKit** — net computation. Pure, unit-tested.
- **CanvasUI** — UIKit canvas view: rendering, pan/zoom, hit testing, tools, touch handling.
- **PhotoPartStudio** — photo → part editor (cutout, scale, pins).
- **App** — SwiftUI shell, `DocumentGroup`, toolbars, library sidebar, export.

### Units and coordinates

- World units: millimetres (Double). Canvas is unbounded.
- View transform (pan, zoom) maps mm → points. Zoom range at least 5%–3200%.
- Fritzing SVG sizes (in/mm/px) converted to mm on import.

### Scene model

Document = ordered list of objects (z-order), each with stable UUID:

- **InkStroke**: points (x, y in mm, pressure, optional tilt/azimuth, time offset), tool (pen, pencil, marker, highlighter), color, base width.
- **Shape**: line, arrow, rectangle, ellipse; stroke/fill style.
- **Text**: string, font size (mm), position, rotation.
- **PartInstance**: reference to part definition (library id + version hash), position, rotation (90° steps in v1; my call), optional label (e.g. "R1"), property values (e.g. resistance 10 kΩ).
- **Wire**: two endpoints + ordered bend points (mm), color. Each endpoint is either attached `(partInstanceID, connectorID)` or free (position).
- **Image**: placed raster image (reference photos, screenshots).

Groups/layers: not in v1 (my call).

Derived, not stored: plugged contacts and nets (recomputed from geometry + model).

### Part definition

Mirrors Fritzing's model so import/export is lossless for what v1 uses:

- id, title, family, properties (key/value, e.g. resistance, package), tags.
- Breadboard graphic: SVG (Fritzing) or raster image with alpha mask (photo parts), size in mm.
- Connectors: id, name, description, type (`male` | `female` | `pad`), position + small hit area in part-local mm, optional pin role (power, ground, digital, analog, I²C SDA/SCL, SPI, UART, other).
- **Buses**: groups of connector ids that are electrically connected inside the part (breadboard rows/rails; ESP32 multiple GND pins).

Parts embedded into the document on first use (copy of definition + graphics), so documents open on any device without the library.

### Parts library

- **Bundled catalog**: curated subset of [fritzing-parts](https://github.com/fritzing/fritzing-parts), converted at build time by a script in the repo. Minimum set: ESP32 dev boards (DevKitC, common 30/38-pin variants), full + half breadboard, resistor, LED, push button, potentiometer, common sensors (DHT22, BME280, HC-SR04, PIR, photoresistor), jumper-friendly modules. Attribution file included.
- **Import**: `.fzpz` via Files / share sheet.
- **Personal library**: photo parts + imported parts, stored in the app's iCloud container so they're on all devices.
- Library sidebar: search by title/tag/family, drag (or tap-to-place) onto canvas.
- SVG rendering: needs a non-GPL SVG→CGPath/image library (candidate: SwiftDraw, zlib license). Builder's choice; must render Fritzing breadboard SVGs correctly at all zoom levels.

### Wires and connections

- Wire tool: start on a connector (snaps within a tolerance), tap to add bend points, end on a connector or leave free. Pencil or finger.
- Moving/rotating a part moves attached wire endpoints; bend points stay.
- Dragging a wire endpoint off a connector detaches it.
- **Plugging**: when a part is dropped, each of its `male` connectors within snap tolerance (~1 mm, my call) of a `female` connector on another part (breadboard, header) snaps the part so the pins align and creates a contact. Moving the part away breaks contacts.
- Tap a connector → highlight its whole net and show pin name + role.

### Nets

Union-find over connectors, edges from: wires (both ends attached), plugged contacts, buses inside a part. Recomputed incrementally or fully on every model change (full recompute fine at v1 sizes: <1000 parts). Net names: auto (`N1`…), or derived from a pin role like GND/3V3 when unambiguous.

### Photo parts (PhotoPartStudio)

1. Source: camera or Photos picker.
2. Auto cutout: Vision `VNGenerateForegroundInstanceMaskRequest`. If several instances are found, user picks one.
3. Refine: Pencil brush adds/erases mask; adjustable brush size; zoomable.
4. Manual alternative: trace outline with Pencil (closed lasso/polygon) instead of auto mask.
5. Crop + rotate to straighten.
6. Scale calibration: mark two points and enter their real distance (default 2.54 mm), or enter overall width in mm.
7. Pins: tap to place; name, type and role per pin; optional snap to a 2.54 mm grid anchored at the first pin; define buses (e.g. multiple GND).
8. Metadata: title, family, tags, properties.
9. Save to personal library. Stored as our own format; export as `.fzpz` (breadboard SVG embedding the PNG).

Perspective correction: not in v1 (my call); user should shoot top-down.

### Canvas interaction

- Pencil draws with the active tool; finger: one-finger select/move (my call; Concepts-like), two-finger pan/pinch, two-finger tap undo, three-finger tap redo.
- Tools: pen, pencil, marker, highlighter, stroke eraser, lasso select, shapes, text, wire, part placement.
- Selection: move, rotate (parts: 90° steps), delete, duplicate, copy/paste between documents.
- Pencil 2 double-tap: switch to eraser (configurable).
- Snapping: optional grid (mm), connector snapping always on for wires/plugging.

### Rendering

- Core Animation layers, one per visible object or per tile — builder decides, but must stay smooth (≥60 fps pan/zoom, ink latency matching spike) with ~5k ink strokes + 100 parts on iPad8,11.
- Renderer behind an interface so a Metal backend can replace it later.
- Re-rasterize vector content after zoom settles (crisp at all zoom levels).

### Documents and storage

- `DocumentGroup` with a package document type `.flysketch` (directory: `document.json` + `assets/` for embedded part graphics and images). JSON with a `formatVersion` for migrations.
- Stored wherever Files puts it (iCloud Drive by default).
- Autosave via document architecture. Undo via `UndoManager` with command objects in SketchCore.

### Export

- PNG (selection or whole drawing, chosen scale/DPI), PDF (vector), SVG (vector; ink as filled outline paths, parts as embedded SVG/PNG).
- BOM CSV: part title, label, key properties, quantity (grouped).
- Netlist CSV: net name, connected `label.pinName` list.
- Share sheet.

### Testing

- Unit tests: SketchCore (commands, undo, document round-trip), NetKit (buses, contacts, wires, edge cases), PartsKit (parse real Fritzing parts from the bundled set), InkEngine geometry.
- Manual on-device checks for ink feel and performance on iPad8,11.

## Future (not v1, keep model open for it)

- **Mechanical joints**: connectors gain a kind (`electrical` | `mechanical`); joint types fixed, hinge, slide, pin-in-slot; live planar motion via own Swift constraint solver (Newton-Raphson on joint constraints). No GPL solvers (SolveSpace).
- DXF export/import, schematic view, Mac app, ERC warnings (e.g. 5 V on a 3.3 V pin) from pin roles.

## Left to the builder

- Package boundaries and file layout details.
- Layer/tile strategy for rendering, hit-testing structures (e.g. R-tree).
- SVG library choice (non-GPL).
- Exact JSON schema.
- Catalog conversion script language/tooling.
- UI layout of toolbars and sidebar (iPad conventions, Pencil-first).
