# FlyingSketch Plan 4 — Export

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export a sketch (whole drawing or the current selection) as PNG (chosen DPI), vector PDF and vector SVG. Also export a bill of materials and a netlist as CSV. Every export ends in the iPad share sheet.

**Architecture:** A new `ExportKit` target holds all export logic. It has no UIKit or SwiftUI and depends on `SketchCore`, `InkEngine`, `NetKit`, `PartsKit` and SwiftDraw.
- `ExportContent` resolves the scope (whole drawing or selection) to objects in z-order plus content bounds in mm.
- `SceneDrawer` draws content into any `CGContext` in mm, y-down. PNG (bitmap context) and PDF (`CGContext` PDF) share it, so they look the same.
- `SVGWriter` writes SVG text directly, from the same geometry.
- `CSVWriter`, `BOMExporter` and `NetlistExporter` are pure string builders.

Geometry that the canvas already computes privately (rect normalisation, arrow barbs, wire free-end radius) moves into `SketchCore`. The canvas and the exporters then use one definition and cannot drift. The app adds an Export menu, an `ExportSheet` with options and a preview line, and a `ShareLink` on a generated temp file.

**Tech Stack:** Swift 6, SwiftUI, CoreGraphics, CoreText, ImageIO, UniformTypeIdentifiers, SwiftDraw 0.30.0 (already a dependency), PDFKit (tests only), Swift Testing, xcodegen.

**Spec:** `docs/superpowers/specs/2026-11-18-flyingsketch-v1-design.md`. Relevant sections: Goals 7, "Export", the anti-goal "Two disconnected worlds … separate … export".

## Global Constraints

Everything in the Plan 1–3 Global Constraints still holds: iPadOS 26; Swift 6 strict concurrency; xcodegen; team `WDJPX25GFC`; bundle id `com.flyingturtle.flyingsketch`; no GPL; no `.metal`; MIT; world units are mm as `Double`, y-down; `onChange` is always chained.

Plan 4 adds these:

- **No new third-party dependencies.** SwiftDraw 0.30.0 is already pinned. Use its `CGContext.draw(_ svg: SVG, in rect: CGRect?)`.
- **`ExportKit` must not import UIKit or SwiftUI.** The macOS build must work. Allowed imports: Foundation, CoreGraphics, CoreText, ImageIO, UniformTypeIdentifiers, SwiftDraw. Every public type is a `Sendable` value. Every public function is synchronous and non-isolated, so the app can run it off the main actor.
- **The document format is unchanged** (`formatVersion` stays 2).
- **What an export contains:** only scene objects. No grid, selection handles, net highlight or PNG connector rings (those are view aids).
- **Fixed values:**

  | Value | Setting |
  |---|---|
  | Margin around content | **5 mm** on every side |
  | PNG DPI choices | **150 / 300 / 600**, default **300** |
  | PNG background | **White** (default) or **Transparent** |
  | PNG caps | edge **≤ 16 384 px**, total **≤ 50 000 000 px**; above that, lower the DPI to fit and report the effective DPI |
  | PDF unit | 1 mm = 72 / 25.4 pt, one page = content bounds + margin |
  | SVG size | `width="{w}mm" height="{h}mm" viewBox="{minX} {minY} {w} {h}"` in world mm |
  | SVG numbers | `en_US_POSIX`, at most 3 decimals, trailing zeros trimmed (`1.5`, `-5`, `0.125`) |
  | Vector ink `pixelSize` | **0.02 mm** |
  | Raster ink `pixelSize` | 25.4 / dpi mm |
  | Text font | Helvetica (the canvas font), size = `fontSize` mm, left aligned, first line top at `position` |
  | Highlighter | alpha **0.35**, multiply blend (CG `.multiply`; SVG `style="mix-blend-mode:multiply"`) |
  | Missing / unreadable part graphic | the canvas placeholder: dashed **10 mm** square, gray 0.4 |
  | CSV | UTF-8 with BOM `\u{FEFF}`, `\r\n` line ends, RFC 4180 quoting |
  | Export file names | `<document name>[ (selection)].png/.pdf/.svg`, `<document name> BOM.csv`, `<document name> Netlist.csv`; fallback name `Sketch` |

- **BOM and netlist always cover the whole document.** The scope choice applies to PNG / PDF / SVG only.
- **Netlist pins** are `label.name`. An empty label falls back to the definition title. An empty connector name falls back to the connector id. Members of parts whose definition `family` equals `breadboard` (case-insensitive) are omitted. Nets left with fewer than 2 pins are omitted.
- **Commands:**
  - Package tests: `cd Packages/FlyingSketchKit && xcodebuild test -scheme FlyingSketchKit-Package -destination 'platform=iOS Simulator,id=08D1B7B4-263D-4479-8F34-C24730978306' -quiet`.
  - App build: `xcodegen generate && xcodebuild -project FlyingSketch.xcodeproj -scheme FlyingSketch -destination 'platform=iOS Simulator,id=08D1B7B4-263D-4479-8F34-C24730978306' -quiet build`.

## Review Focus

1. **Rotated parts and bent legs.** For `quarterTurns` 1 and 3 with custom `legEnds`, the graphic and the legs must land where the canvas shows them. Tests: Task 4 `quarterTurnRotatesPart`, `legsDrawToTheirEnds`.
2. **Huge drawing at 600 dpi.** A 5 m wide sketch must not run out of memory or crash. The DPI is lowered and reported. Test: Task 5 `hugeDrawingReducesDPI`.
3. **Nothing to export.** An empty document, or an empty or stale selection, gives `ExportError.nothingToExport` with readable text, never an empty file. Test: Task 2 `emptyScopeThrows`.
4. **User text with markup or CSV characters.** Text such as `a<b & "c"` and labels/properties containing `,`, `"` or newlines must give valid SVG and valid CSV. Tests: Task 2 `csvQuotesSpecialFields`, Task 6 `textIsEscaped`.
5. **Broken assets.** A part whose definition is missing, a graphic that is not a valid SVG/PNG, or an image asset that is missing must draw a placeholder or be skipped. The export still succeeds. Tests: Task 4 `brokenPartsDrawPlaceholder`, Task 3 `missingImageIsSkipped`.

---

### Task 1: Shared scene geometry in SketchCore

**Files:**
- Create: `Packages/FlyingSketchKit/Sources/SketchCore/Query/SceneGeometry.swift`
- Modify: `Packages/FlyingSketchKit/Sources/CanvasUI/Rendering/ObjectLayerFactory.swift` (shape at ~:145-170 and wire at ~:230-250 use the new helpers; `freeEndRadius` moves)
- Test: `Packages/FlyingSketchKit/Tests/SketchCoreTests/SceneGeometryTests.swift`

**Interfaces:**
- Produces (all `public`, in SketchCore):
  - `enum ShapeGeometry { static func rect(of s: ShapeObject) -> Rect; static func arrowBarbs(of s: ShapeObject) -> (Vec2, Vec2)? }`. `rect` is the normalised bbox of `start`/`end`. `arrowBarbs` is nil for non-arrows and zero-length arrows. Otherwise it returns the two barb end points: head length `max(lineWidth * 5, 4)` mm, from `end` along `dir.rotated(by: .pi ± 0.45)`. This is the canvas formula, moved unchanged.
  - `extension Wire { static let freeEndRadius: Double = 0.6 }`. It replaces `CALayerObjectFactory.freeEndRadius`, and every use is updated.
  - `func contentBounds(of objects: [SceneObject], in doc: SketchDocument) -> Rect?`. It is the union of `bounds(of:in:)`, extended by arrow barbs and wire free-end circles (radius + width/2). It returns nil for `[]`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func arrowBarbsMatchCanvasFormula() {
    let s = ShapeObject(kind: .arrow, start: Vec2(x: 0, y: 0), end: Vec2(x: 10, y: 0), lineWidth: 0.5)
    let (a, b) = try #require(ShapeGeometry.arrowBarbs(of: s))
    let head = 4.0 // max(0.5*5, 4)
    #expect(abs(a.x - (10 - head * cos(0.45))) < 1e-9)
    #expect(abs(abs(a.y) - head * sin(0.45)) < 1e-9)
    #expect(abs(a.y + b.y) < 1e-9)          // symmetric
    #expect(ShapeGeometry.arrowBarbs(of: ShapeObject(kind: .line, start: .zero, end: Vec2(x: 1, y: 0))) == nil)
    #expect(ShapeGeometry.arrowBarbs(of: ShapeObject(kind: .arrow, start: .zero, end: .zero)) == nil)
}
@Test func shapeRectIsNormalised() {
    let s = ShapeObject(kind: .rectangle, start: Vec2(x: 10, y: 8), end: Vec2(x: 2, y: 3))
    #expect(ShapeGeometry.rect(of: s) == Rect(origin: Vec2(x: 2, y: 3), size: Vec2(x: 8, y: 5)))
}
@Test func contentBoundsIncludesFreeWireEnds() {
    let w = Wire(start: WireEnd(position: Vec2(x: 0, y: 0)), end: WireEnd(position: Vec2(x: 10, y: 0)), width: 0.65)
    let doc = SketchDocument(objects: [.wire(w)])
    let r = try #require(contentBounds(of: doc.objects, in: doc))
    #expect(abs(r.minX - (-(0.6 + 0.325))) < 1e-9)
    #expect(contentBounds(of: [], in: doc) == nil)
}
```

Adapt the initializer labels to the real model inits. Keep the asserted values.

- [ ] **Step 2: Run, expect a compile failure** (`ShapeGeometry` is undefined).
- [ ] **Step 3: Implement `SceneGeometry.swift`.** Then switch `CALayerObjectFactory` to `ShapeGeometry.rect`, `ShapeGeometry.arrowBarbs` and `Wire.freeEndRadius`. Canvas behaviour must be unchanged.
- [ ] **Step 4: Run the full package tests.** They pass, and the existing CanvasUITests stay green.
- [ ] **Step 5: Commit** `refactor(core): shared shape/wire geometry + contentBounds`.

### Task 2: ExportKit target, content scope, CSV, BOM, netlist

**Files:**
- Modify: `Packages/FlyingSketchKit/Package.swift`. Add target `ExportKit` (deps `SketchCore`, `InkEngine`, `NetKit`, `PartsKit`, SwiftDraw product), product `ExportKit`, and testTarget `ExportKitTests` (deps `ExportKit`, `SketchCore`, `NetKit`).
- Modify: `project.yml`. Add the `ExportKit` package product to the app target.
- Create: `Sources/ExportKit/ExportContent.swift`, `Sources/ExportKit/CSV.swift`, `Sources/ExportKit/BOMExporter.swift`, `Sources/ExportKit/NetlistExporter.swift`
- Test: `Tests/ExportKitTests/ContentTests.swift`, `Tests/ExportKitTests/CSVTests.swift`, `Tests/ExportKitTests/TestSupport.swift` (doc builder shared by later ExportKit tests: `add(def, at:, label:, properties:, quarterTurns:, legEnds:)`, `wire(_:_:)`, like NetKitTests' private `Fix`)

**Interfaces:**
- Consumes: `contentBounds(of:in:)` (Task 1), `nets(in:)` and `Net` (NetKit).
- Produces:
  - `public enum ExportScope: Hashable, Sendable { case all; case selection(Set<ObjectID>) }`
  - `public enum ExportError: Error, Equatable, Sendable, LocalizedError { case nothingToExport, tooLarge, encodingFailed }`. Text: "Nothing to export." / "The drawing is too large to export." / "The file couldn't be created."
  - `public struct ExportContent: Sendable { public let document: SketchDocument; public let objects: [SceneObject]; public let bounds: Rect }`. `bounds` includes the margin.
  - `public static func make(_ doc: SketchDocument, scope: ExportScope, margin: Double = 5) throws(ExportError) -> ExportContent`. Objects keep document z-order. Ids not in the document are ignored.
  - `enum CSV { static func field(_ s: String) -> String; static func document(_ rows: [[String]]) -> String }` (internal). `document` adds the BOM, joins with `,` and ends every row with `\r\n`.
  - `public enum BOMExporter { static func csv(_ doc: SketchDocument) -> String }`. Header `Quantity,Title,Labels,Properties`. Properties are the definition properties merged with the instance properties (instance wins), excluding key `family` (case-insensitive) and empty values. They are sorted by key and written as `key=value` joined by `; `. Rows are grouped by (title, properties string) and sorted by title, then properties. Labels are sorted with `localizedStandardCompare` and joined by a space. A part with a missing definition gets title `Unknown part (<definitionKey>)`.
  - `public enum NetlistExporter { static func csv(_ doc: SketchDocument) -> String }`. Header `Net,Pins`. Rows follow `nets(in:)` order, with the pin rules from Global Constraints. Pins are unique, sorted with `localizedStandardCompare`, and joined by a space.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func emptyScopeThrows() {
    let doc = SketchDocument.fixtureThreeStrokes()
    #expect(throws: ExportError.nothingToExport) { try ExportContent.make(SketchDocument(), scope: .all) }
    #expect(throws: ExportError.nothingToExport) { try ExportContent.make(doc, scope: .selection([])) }
    #expect(throws: ExportError.nothingToExport) { try ExportContent.make(doc, scope: .selection([ObjectID()])) }
    #expect(ExportError.nothingToExport.localizedDescription == "Nothing to export.")
}
@Test func selectionKeepsZOrderAndAddsMargin() throws {
    let doc = SketchDocument.fixtureThreeStrokes()
    let ids = Set([doc.objects[2].id, doc.objects[0].id])
    let c = try ExportContent.make(doc, scope: .selection(ids))
    #expect(c.objects.map(\.id) == [doc.objects[0].id, doc.objects[2].id])
    let raw = try #require(contentBounds(of: c.objects, in: doc))
    #expect(c.bounds == raw.insetBy(-5))   // use the real Rect inset API
}
@Test func csvQuotesSpecialFields() {
    #expect(CSV.field("plain") == "plain")
    #expect(CSV.field("a,\"b\"\nc") == "\"a,\"\"b\"\"\nc\"")
    #expect(CSV.document([["a", "b"], ["1", "2"]]) == "\u{FEFF}a,b\r\n1,2\r\n")
}
@Test func bomGroupsByTitleAndProperties() {
    // R1, R10, R2 with resistance=220Ω (defined as an instance property), R3 with resistance=1kΩ,
    // a mini breadboard BB1, and an I2C module with label "U1, main" (comma).
    let csv = BOMExporter.csv(doc)
    #expect(csv == "\u{FEFF}Quantity,Title,Labels,Properties\r\n" +
        "1,I2C Module,\"U1, main\",\r\n" +
        "1,Mini Breadboard,BB1,\r\n" +
        "1,Resistor,R3,resistance=1kΩ\r\n" +
        "3,Resistor,R1 R2 R10,resistance=220Ω\r\n")
}
@Test func netlistUsesLabelDotPinAndSkipsBreadboards() {
    // R1.b wired to R2.a; R2.b plugged into breadboard row r0 together with U1 VCC (plugged), so net = R2.b + VCC;
    // a dangling wire from R3.a to nothing (1 pin, omitted).
    let csv = NetlistExporter.csv(doc)
    #expect(csv == "\u{FEFF}Net,Pins\r\nVCC,R2.b U1.VCC\r\nN1,R1.b R2.a\r\n")  // order = nets(in:) order
}
```

Build the docs in `TestSupport`. Adjust the expected net order to what `nets(in:)` returns: assert that order, not a guess. Keep the row contents exact. The `1kΩ`/`220Ω` order follows plain string sort of `resistance=1kΩ` < `resistance=220Ω`.

- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement.** Use exact string building; no `Formatter`s for CSV.
- [ ] **Step 4: Run the package tests, then the app build** (the project.yml dependency must resolve). Both pass.
- [ ] **Step 5: Commit** `feat(export): ExportKit target, scope, BOM + netlist CSV`.

### Task 3: SceneDrawer — ink, shapes, wires, text, images

**Files:**
- Create: `Sources/ExportKit/SceneDrawer.swift`, `Sources/ExportKit/TextLayout.swift`, `Sources/ExportKit/ImageDecoding.swift`
- Test: `Tests/ExportKitTests/SceneDrawerTests.swift`, plus `TestSupport.swift` helpers: `render(_ content: ExportContent, pxPerMM: Double) -> CGImage` (white RGBA bitmap, CTM mapping `content.bounds` mm y-down) and `pixel(_ img: CGImage, mmX:, mmY:, bounds:, pxPerMM:) -> (r, g, b, a: Double)`

**Interfaces:**
- Consumes: `StrokeOutline.polygon(_:baseWidth:tool:gamma:pixelSize:)` (InkEngine), `ShapeGeometry`, `Wire.freeEndRadius`, `Wire.polyline`.
- Produces:
  - `public enum SceneDrawer { static func draw(_ content: ExportContent, in ctx: CGContext, pixelSize: Double) }`. The caller has already set the CTM so that 1 unit = 1 mm, y-down, with the origin at world (0, 0). The drawer saves and restores the gstate for each object.
  - `enum TextLayout { static func lines(_ t: TextObject) -> [(text: String, baselineY: Double)] }` (internal; used again by Task 6). It uses a CTFont Helvetica of size `fontSize`: `baselineY_i = ascent + i * (ascent + descent + leading)`, relative to `position`, before rotation.
  - `enum ImageDecoding { static func cgImage(_ data: Data) -> CGImage? }` (internal; ImageIO, max pixel size 8192, nil on failure).
- Drawing rules, which mirror `CALayerObjectFactory`:
  - Ink is a filled outline polygon (non-zero winding), with the highlighter rule from Global Constraints.
  - Shapes use round caps and joins. Only rect and ellipse are filled. The arrow is the shaft plus the two barbs.
  - A wire is a stroked polyline plus a stroked circle at each end without an attachment.
  - Text is drawn with CoreText, rotated by `rotation` about `position`. Glyphs must be upright in the y-down CTM, so flip the text matrix.
  - An image is drawn into `frame`, rotated about the frame centre. A missing or undecodable asset is skipped.

- [ ] **Step 1: Write the failing tests** (10 px/mm render, black ink on a white background unless noted)

```swift
@Test func inkStrokeFillsItsOutline()   // pen stroke (10,10)->(30,10), width 2, pressure 1: (20,10) dark (r<0.2); (20,14) white
@Test func highlighterMultiplies()       // red filled rect under a yellow highlighter stroke: pixel r>0.8, g<0.2
@Test func arrowDrawsBarbs()             // arrow (0,0)->(20,0) width 0.5: pixel at the barb midpoint is dark
@Test func wireFreeEndCircle()           // free wire end at (10,10): pixel at (10.6,10) dark, (10,10) white (circle not filled)
@Test func textDrawsBelowAndRightOfPosition()   // "H" fontSize 10 at (10,10): dark pixel inside x 10…17, y 10…20; none at y<9.5 or x<9.5
@Test func rotatedTextTurnsClockwise()   // same text, rotation .pi/2: dark pixels inside x 0…10, y 10…17; none at x>10.5
@Test func imageObjectDrawsRotated()     // 2×1 px PNG (left red, right blue), frame (10,10,20,10), rotation .pi: pixel (14,15) blue, (26,15) red
@Test func missingImageIsSkipped()       // ImageObject with an unknown asset name plus one ink stroke: draw does not crash, the stroke is present
```

Create the PNG fixture bytes in the test with a `CGBitmapContext` and ImageIO. Do not use the fake fixture headers.

- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement.** Parts are a no-op in this task (Task 4).
- [ ] **Step 4: Run, pass.**
- [ ] **Step 5: Commit** `feat(export): SceneDrawer for ink, shapes, wires, text, images`.

### Task 4: SceneDrawer — parts

**Files:**
- Modify: `Sources/ExportKit/SceneDrawer.swift`
- Test: `Tests/ExportKitTests/PartDrawingTests.swift`

**Interfaces:**
- Consumes: `PartInstance.bodyRect(in:)`, `legSegment(for:in:)`, `localToWorld` (SketchCore), `PartInputGuard.isAcceptableSVG(_:)` (PartsKit), SwiftDraw `SVG(data:)` and `CGContext.draw(_:in:)`, `ImageDecoding`.
- Rules:
  - Draw the graphic into the part-local rect `(0, 0, def.size)`. The transform is translate to `center`, rotate `quarterTurns * .pi/2` (clockwise on y-down), then translate by `-size/2`.
  - Legs are drawn after the body, from origin to the end, with leg colour and width and round caps. Match the canvas leg/body order in `PartLayer`; if the canvas draws legs below the body, do the same and change the test's expectation accordingly.
  - The placeholder (Global Constraints) is used for: a missing definition, an SVG that fails `isAcceptableSVG` or `SVG(data:)`, and a PNG that fails to decode.
  - SVG parts stay vector in PDF, because SwiftDraw issues path commands.

- [ ] **Step 1: Write the failing tests**

Use real SVG bytes built in the test, e.g. `<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="4mm" viewBox="0 0 10 4"><rect width="5" height="4" fill="#ff0000"/><rect x="5" width="5" height="4" fill="#0000ff"/></svg>`. Assign it to the fixture definition's `graphicAsset`.

```swift
@Test func svgPartDrawsAtCenter()      // q=0, center (20,20): (18,20) red, (22,20) blue, (26,20) white
@Test func quarterTurnRotatesPart()     // q=1: (20,18) red, (20,22) blue; q=3: (20,18) blue, (20,22) red
@Test func pngPartDraws()               // graphicKind .png with a 2×1 red|blue PNG: same pixels as svgPartDrawsAtCenter
@Test func legsDrawToTheirEnds()        // resistor (real svg) with legEnds["a"] = center + (0, 15): pixel on that leg 10 mm below the center has the leg colour
@Test func brokenPartsDrawPlaceholder() // (1) missing definition, (2) svg bytes "not svg", (3) png bytes Data([1,2,3]): no crash; ≥1 non-white pixel on the placeholder's top edge
```

- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, pass.**
- [ ] **Step 5: Commit** `feat(export): draw parts (svg/png, rotation, legs, placeholder)`.

### Task 5: PNG and PDF exporters

**Files:**
- Create: `Sources/ExportKit/RasterExporter.swift`, `Sources/ExportKit/PDFExporter.swift`
- Test: `Tests/ExportKitTests/RasterPDFTests.swift` (imports PDFKit)

**Interfaces:**
- Consumes: `SceneDrawer.draw`, `ExportContent`.
- Produces:
  - `public struct PNGOptions: Hashable, Sendable { public var dpi: Double = 300; public var background: Background = .white; public enum Background: Hashable, Sendable { case white, transparent } }`
  - `public struct RasterResult: Sendable { public let data: Data; public let width: Int; public let height: Int; public let effectiveDPI: Double }`
  - `public enum RasterExporter { static func plan(_ content: ExportContent, options: PNGOptions) throws(ExportError) -> (width: Int, height: Int, effectiveDPI: Double); static func png(_ content: ExportContent, options: PNGOptions) throws(ExportError) -> RasterResult }`. `plan` is cheap; the sheet uses it for its size line. Size is `ceil(mm * dpi / 25.4)` per axis. When a cap is exceeded, `effectiveDPI` is the largest DPI that fits both caps (Global Constraints). Below 1 dpi, it throws `.tooLarge`. The bitmap is 8-bit RGBA sRGB, premultiplied. The PNG embeds the DPI in its metadata (`kCGImagePropertyDPIWidth/Height`). An encoder failure throws `.encodingFailed`.
  - `public enum PDFExporter { static func pdf(_ content: ExportContent) throws(ExportError) -> Data }`. One page with media box `bounds * 72/25.4`. Flip to y-down mm before calling `SceneDrawer` with `pixelSize` 0.02.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func pngSizeFollowsDPI()        // content 100×50 mm (+5 margin each side) at 254 dpi → 1100×600, effectiveDPI 254; PNG decodes to that size
@Test func pngBackgrounds()           // corner pixel white: (1,1,1,1); transparent: a == 0
@Test func hugeDrawingReducesDPI()    // shape spanning 5000×5000 mm at 600 dpi: effectiveDPI < 600, width ≤ 16384, width*height ≤ 50_000_000; use `plan` (do not allocate in the test)
@Test func pdfPageSizeInPoints()      // content 100×50 → 1 page, mediaBox ≈ (110*72/25.4, 60*72/25.4) ±0.01
@Test func pdfKeepsTextAsText()       // TextObject "Hello FlyingSketch" → PDFDocument(data:)!.string contains it
@Test func pdfMatchesPNGLayout()      // render the PDF page to a bitmap at 10 px/mm with CGPDFPage and compare 3 pixels with the PNG of the same content (y not flipped)
```

- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, pass.**
- [ ] **Step 5: Commit** `feat(export): PNG (dpi, caps, background) and vector PDF`.

### Task 6: SVG exporter

**Files:**
- Create: `Sources/ExportKit/SVGWriter.swift`
- Test: `Tests/ExportKitTests/SVGTests.swift`

**Interfaces:**
- Consumes: `ExportContent`, `StrokeOutline.polygon` (pixelSize 0.02), `ShapeGeometry`, `TextLayout.lines`, `Wire.freeEndRadius`, `PartInputGuard.isAcceptableSVG`, `ImageDecoding`.
- Produces: `public enum SVGWriter { static func svg(_ content: ExportContent) -> Data }` (UTF-8, starting with `<?xml version="1.0" encoding="UTF-8"?>`).
- Element per object, as a direct child of the root, in z-order:
  - ink `<path d="M…Z" fill="#rrggbb">`;
  - shape `<line>` / `<path>` (arrow: shaft + barbs) / `<rect>` / `<ellipse>`;
  - text `<text font-family="Helvetica, Arial, sans-serif" font-size="…" transform="rotate(deg x y)">` with one `<tspan x y>` per line;
  - image `<image href="data:…;base64,…" preserveAspectRatio="none" transform="rotate(…)">`;
  - part `<g transform="translate(cx cy) rotate(90q) translate(-w/2 -h/2)">` holding `<image width height href="data:image/svg+xml;base64,…">` (or `image/png`), followed by the leg `<line>`s in world coordinates outside that `<g>` but inside a wrapping `<g>`, so a part is exactly one child;
  - wire `<g>` with a `<polyline fill="none">` and `<circle fill="none">` per free end.
- Colour `#rrggbb`; alpha < 1 adds `fill-opacity` / `stroke-opacity`. The highlighter rule is in Global Constraints. Images that are not PNG or JPEG are transcoded to PNG. A missing image is omitted. A broken part becomes the placeholder `<rect stroke-dasharray>`. Text content and attributes are XML-escaped (`&`, `<`, `>`, `"`, `'`).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func svgRootUsesMillimetres()    // content (0,0)-(100,50): width="110mm" height="60mm" viewBox="-5 -5 110 60"
@Test func oneChildPerObjectInZOrder() // fixtureWithEveryKind plus a part and a wire: XMLParser root children = ["path","path","text",…] per object kind
@Test func textIsEscaped()             // text `a<b & "c"` parses with XMLParser; joined tspan text == `a<b & "c"`
@Test func partsEmbedDataURI()         // svg part → base64 payload decodes to the asset bytes; png part uses data:image/png
@Test func highlighterUsesMultiply()   // highlighter path has opacity="0.35" and mix-blend-mode:multiply
@Test func numbersArePOSIX()           // stroke at x 1.5 → "1.5" present, no "1,5" in any numeric attribute; 1/3 → "0.333"
```

- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement** with a small internal `XMLEscape` and a number formatter (a `String(format:)` POSIX-free `Double` formatter that rounds to 3 decimals and trims zeros).
- [ ] **Step 4: Run, pass.**
- [ ] **Step 5: Commit** `feat(export): vector SVG writer`.

### Task 7: App — Export menu, sheet, share

**Files:**
- Create: `App/Export/ExportFormat.swift`, `App/Export/ExportSheet.swift`, `App/Export/ExportJob.swift`
- Modify: `App/Views/SketchEditorView.swift` (Export menu in the `ToolPalette` accessory at ~:47; sheet state)

**Interfaces:**
- Consumes: everything public in ExportKit; `SelectionState.ids`; `document.model.document`; `@Environment(\.documentConfiguration)`.
- Produces (app-internal):
  - `enum ExportFormat: String, CaseIterable, Identifiable { case png, pdf, svg, bom, netlist }`, with `title` ("Image (PNG)", "PDF", "SVG", "Bill of Materials (CSV)", "Netlist (CSV)"), `fileExtension` and `usesScope` (png/pdf/svg).
  - `struct ExportRequest: Hashable, Sendable { var format; var scope: ExportScope; var png: PNGOptions }`
  - `enum ExportJob { @concurrent static func run(_ request: ExportRequest, document: SketchDocument, baseName: String) async throws -> URL }`. It writes into a fresh `FileManager.default.temporaryDirectory/Export-<UUID>/` and removes the previous export directory it created. It checks for `Task.isCancelled` before writing.
- UI:
  - An Export `Menu` (`square.and.arrow.up`) in the accessory HStack, before the updates button, lists the 5 formats. Each one opens `ExportSheet(format:)`.
  - `ExportSheet` is a `NavigationStack` + `Form`:
    - Scope picker "Whole drawing" / "Selection (N objects)". Disabled when the selection is empty. The default is Selection when there is one. Shown only for `usesScope`.
    - PNG only: a Resolution segmented picker (150/300/600 dpi) and a Background segmented picker (White/Transparent).
    - A size line: PNG `"W × H px"`, plus `" (reduced to N dpi)"` when `effectiveDPI < dpi`, from `RasterExporter.plan`; PDF/SVG `"W × H mm"`; CSV none.
  - `.task(id: request)` regenerates the file off-main. The sheet shows a `ProgressView` with "Preparing…" until it is ready. Then `ShareLink(item: url)` labelled "Share" is enabled. Errors show `localizedDescription` inline in red; for example, an empty document shows "Nothing to export."
  - The document snapshot is taken on the main actor when the sheet opens. "Done" dismisses the sheet.
- Base name: `fileURL` without its extension, else `Sketch`. Append ` (selection)` for a selection scope. Append ` BOM` / ` Netlist` for CSV. Replace `/` and `:` with `-`.

- [ ] **Step 1: Implement the views and `ExportJob`.**
- [ ] **Step 2: App build passes. Package tests stay green.**
- [ ] **Step 3: Simulator smoke check.** Open a document with ink and a part. Export PNG at 300 dpi: the sheet shows a size and Share opens the share sheet. Export Netlist: Share is enabled. On an empty document, PNG shows "Nothing to export.".
- [ ] **Step 4: Commit** `feat(app): export menu, options sheet, share`.

---

## Hand check (Lars, on iPad)

1. Draw ink (pen + highlighter), a rotated text, an arrow, an ESP32 + resistors on a breadboard, and wires. Export PNG at 300 dpi and open it in Photos: it matches the canvas.
2. Export PDF and open it in Files: zoom in, and lines, parts and text stay sharp. Text is selectable.
3. Export SVG and open it in Safari: it matches the canvas.
4. Select 2 parts and export PNG (selection): only those appear, with a 5 mm margin.
5. Export the BOM and the netlist and open them in Numbers: grouping and `R1.leg` pins are right, and no breadboard rows appear.
