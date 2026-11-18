# FlyingSketch Plan 2 — Parts, Wires, Nets

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Draw the ESP32 wiring diagram: place parts from a bundled Fritzing-derived catalog (or imported `.fzpz`), plug them into breadboards, wire pin to pin, stretch resistor/LED legs, and see live nets — all undoable and saved in the document.

**Architecture:** Part/wire data and all connectivity geometry live in `SketchCore` (pure, tested). A new `NetKit` target computes nets. A new `PartsKit` target parses Fritzing parts (ZIP, SVG geometry, `.fzp`) and manages the parts library; a macOS `catalog-builder` executable uses it to generate the bundled catalog. `CanvasUI` renders parts (SVG rasterized via SwiftDraw), wires and legs, and adds the wire tool, plugging, leg dragging and net highlight. The app adds a parts library sheet and an inspector.

**Tech Stack:** Swift 6, SwiftUI, UIKit, Core Animation, Foundation `XMLParser`, Compression, CryptoKit, SwiftDraw (zlib license), Swift Testing, xcodegen.

**Spec:** `docs/superpowers/specs/2026-11-18-flyingsketch-v1-design.md` (sections Part definition, Parts library, Wires and connections, Nets).

## Global Constraints

Everything in Plan 1's Global Constraints still holds (iPadOS 26, Swift 6 strict concurrency, xcodegen, team `WDJPX25GFC`, bundle id `com.flyingturtle.flyingsketch`, no GPL, no `.metal`, MIT, world mm `Double`, zoom 0.05…32, `.flysketch` package). Additions:

- Only third-party dependency allowed: **SwiftDraw** (`https://github.com/swhitty/SwiftDraw`, zlib license) — pin an exact release tag (latest at implementation time), used only by `CanvasUI` for SVG rasterization. Verify its license file is zlib before adding.
- `SketchCore`, `NetKit`, `PartsKit` must not import UIKit/SwiftUI (they also build for macOS for the catalog builder). Package platforms: `.iOS(.v26), .macOS(.v26)`.
- Document `formatVersion` becomes **2** (written always); reader accepts 1 and 2; >2 → `unsupportedVersion`.
- Fritzing parts are CC-BY-SA 3.0: bundled catalog ships `App/Catalog/ATTRIBUTION.md` listing every part's source repo, path, commit and authors from the `.fzp`.
- Snap / tolerance values (mm unless noted): plug snap search radius **1.0**, contact tolerance **0.2**, connector hit radius **max(0.8 mm, 12 pt on screen)**, wire default width **0.65**, leg default width **0.6**.
- Part rotation: quarter turns only (0–3, clockwise), around the part center.
- Every user action = one undoable edit with an action name; never perform empty edits; never replace `DocumentModel.onChange` (chain).
- Test command (package): `cd Packages/FlyingSketchKit && xcodebuild test -scheme FlyingSketchKit-Package -destination 'platform=iOS Simulator,id=08D1B7B4-263D-4479-8F34-C24730978306' -quiet`. macOS-only CLI: `cd Tools/CatalogBuilder && swift run catalog-builder ../catalog-manifest.json ../../Vendor ../custom-parts ../../App/Catalog`.

## Review Focus

1. **Deleting a part with wires attached** must leave the wires with free ends at their last positions in the same undo step; undo restores attachment. → Task 2 `deletingPartDetachesWiresInOneEdit`.
2. **Moving a breadboard** carries plugged parts (transitively) and all attached wire ends in one undo step; undo restores everything. → Task 2 `carryAlongIsTransitiveAndOneEdit`.
3. **Malformed / hostile `.fzpz`** (corrupt ZIP, missing fzp, missing svg, huge declared sizes, path traversal names) fails with a typed error, never crashes or writes outside the library. → Task 4 `rejectsHostileArchives`, Task 6 `importRejectsBrokenParts`.
4. **SVG features the geometry parser doesn't understand** (unknown elements, unsupported transforms) must not lose a connector silently: the part is rejected with an error naming the connector. → Task 5 `missingConnectorGeometryIsAnError`.
5. **Old documents** (formatVersion 1, no parts) open unchanged and are saved as v2; a v3 document is rejected. → Task 1 `readsV1WritesV2`.

---

### Task 1: Part and wire model, format v2

**Files:**
- Create: `Sources/SketchCore/Model/PartDefinition.swift`, `PartInstance.swift`, `Wire.swift`
- Modify: `Sources/SketchCore/Model/SceneObject.swift`, `SketchDocument.swift`, `Sources/SketchCore/Edit/SceneEdit.swift`, `DocumentModel.swift`, `Sources/SketchCore/File/DocumentPackage.swift`, `Sources/SketchCore/Query/HitTesting.swift`, `Sources/SketchCore/Fixtures.swift`
- Test: `Tests/SketchCoreTests/PartModelTests.swift`, `DocumentPackageTests.swift`

**Interfaces:**
- Produces:
  - `public enum ConnectorKind: String, Codable, Sendable { case male, female, pad }`
  - `public enum PinRole: String, Codable, Sendable { case power, ground, digital, analog, i2cSDA, i2cSCL, spi, uart, other }`
  - `public struct LegSpec: Hashable, Codable, Sendable { var origin: Vec2; var defaultEnd: Vec2; var color: RGBAColor; var width: Double }` (part-local mm)
  - `public struct ConnectorDef: Hashable, Codable, Sendable { var id: String; var name: String; var description: String; var kind: ConnectorKind; var position: Vec2 /*part-local mm, top-left origin*/; var role: PinRole?; var leg: LegSpec? }`
  - `public struct PartDefinition: Hashable, Codable, Sendable { var libraryID: String; var versionHash: String; var title: String; var family: String; var labelPrefix: String; var tags: [String]; var properties: [String: String]; var size: Vec2 /*mm*/; var graphicAsset: String /*file name in assets*/; var graphicKind: GraphicKind /*svg, png*/; var connectors: [ConnectorDef]; var buses: [[String]]; var key: String { "\(libraryID)@\(versionHash)" } }`
  - `public struct PartInstance: Hashable, Codable, Sendable { var id: ObjectID; var definitionKey: String; var center: Vec2; var quarterTurns: Int; var label: String; var properties: [String: String]; var legEnds: [String: Vec2] /*connectorID → world mm*/ }`
  - `public enum WireAttachment: Hashable, Codable, Sendable { case connector(part: ObjectID, connector: String) }`
  - `public struct WireEnd: Hashable, Codable, Sendable { var position: Vec2 /*always current world mm*/; var attachment: WireAttachment? }`
  - `public struct Wire: Hashable, Codable, Sendable { var id: ObjectID; var start: WireEnd; var end: WireEnd; var bends: [Vec2]; var color: RGBAColor; var width: Double }`
  - `SceneObject` gains `.part(PartInstance)`, `.wire(Wire)` (JSON `type` `part` / `wire`); `translated(by:)` moves part center + leg ends, wire ends + bends.
  - `SketchDocument` gains `public var parts: [String: PartDefinition]` (keyed by `key`), default `[:]`; `formatVersion` default 2.
  - `SceneEdit` gains `case setDefinitions([String: PartDefinition?])` (nil = remove); inverse restores previous values. `DocumentModel.run` no-op check also compares `parts`.
  - `bounds(of:)`/`hitTest`/`lassoContains` for `.part` need the definition: add `public func bounds(of object: SceneObject, in doc: SketchDocument) -> Rect` and `hitTest(_:point:tolerance:in:)`; existing doc-less overloads keep working for non-part kinds and treat a part as a 10 mm square at `center` (fallback, documented). Wire: polyline start→bends→end, tolerance + width/2.
  - Fixtures (`#if DEBUG`): `PartDefinition.fixtureResistor()` (2 male legged connectors 10.16 mm apart, label "R"), `.fixtureBreadboardMini()` (female 5×4 grid at 2.54 mm, buses per column of 5), `.fixtureModule()` (4 male pins in a row, roles VCC power / GND ground / SDA i2cSDA / SCL i2cSCL).

- [ ] **Step 1: Write failing tests** — `partAndWireRoundTrip` (document with definitions, part, wire round-trips through `DocumentPackage`); `readsV1WritesV2` (v1 JSON without `parts` reads; written JSON has `formatVersion` 2; `{"formatVersion":3,…}` → `.unsupportedVersion(3)`); `setDefinitionsUndo` (perform add + remove definitions, undo restores); `translatedMovesLegEndsAndWireEnds`; `wireHitTest` (point 0.3 mm from a bend segment hits with width 0.65); `validationRejectsAbsurdPartCoordinates` (part center 1e9 → `.corrupt`).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Validation (existing `validate`) also covers part centers, leg ends, wire ends/bends, definition sizes/connector positions, `quarterTurns` in 0…3.
- [ ] **Step 4:** Run. Expected: PASS (all Plan 1 tests still pass).
- [ ] **Step 5:** Commit `feat(core): part, wire and definition model; format v2`.

### Task 2: Connectivity geometry (plugging, carry-along, wire reconciliation)

**Files:**
- Create: `Sources/SketchCore/Connectivity/PartGeometry.swift`, `Plugging.swift`, `PartEdits.swift`
- Test: `Tests/SketchCoreTests/ConnectivityTests.swift`

**Interfaces:**
- Consumes: Task 1 model.
- Produces:
  - `public func localToWorld(_ p: Vec2, instance: PartInstance, definition: PartDefinition) -> Vec2` (rotate `p - size/2` by `quarterTurns × 90°` clockwise, add `center`); `public func connectorPositions(_ instance: PartInstance, _ def: PartDefinition) -> [String: Vec2]` — legged connectors use `legEnds[id]` if present else `localToWorld(leg.defaultEnd)`.
  - `public struct Contact: Hashable, Sendable { var male: ConnectorRef; var female: ConnectorRef }`, `public struct ConnectorRef: Hashable, Sendable { var part: ObjectID; var connector: String }`.
  - `public func contacts(in doc: SketchDocument) -> Set<Contact>` — male (or pad? no: male only) within **0.2 mm** of a female on a *different* part. Uses a spatial hash over female positions (no O(n²) over all pins).
  - `public func plugSnapOffset(for instance: PartInstance, in doc: SketchDocument, excluding: Set<ObjectID>) -> Vec2?` — smallest offset (≤ **1.0 mm**) that puts any male connector exactly on a female of a part not in `excluding`; nil if none.
  - `public func carriedParts(by moving: Set<ObjectID>, in doc: SketchDocument) -> Set<ObjectID>` — transitive closure: parts whose male connectors are plugged into a female of a moving part.
  - `public func moveParts(_ ids: Set<ObjectID>, by delta: Vec2, in doc: SketchDocument) -> [SceneObject]` — returns replaced part instances (centers moved; leg ends moved only if that leg's end is not plugged into a part outside the moving set) **plus** every wire with an end attached to a moved connector, end positions updated. Free wire ends and bends untouched unless the wire itself is in `ids`.
  - `public func rotatePart(_ id: ObjectID, clockwise: Bool, in doc: SketchDocument) -> [SceneObject]` — quarterTurns ±1 mod 4, legs reset to default ends, attached wire ends updated.
  - `public func removeParts(_ ids: Set<ObjectID>, in doc: SketchDocument) -> (removed: Set<ObjectID>, detachedWires: [SceneObject])` — wires attached to removed parts get `attachment = nil`, position unchanged.
  - `public func reconcileWires(in doc: SketchDocument) -> [SceneObject]` — wires whose attached connector moved or vanished: position updated or attachment cleared (used after definition updates, Task 14).

- [ ] **Step 1: Write failing tests** — `connectorPositionsRotate` (resistor fixture rotated 1 turn: leg ends swap axes exactly); `pluggedResistorMakesTwoContacts`; `snapOffsetWithinRadius` (resistor 0.7 mm off a breadboard hole → offset brings it exactly on; 1.3 mm → nil); `carryAlongIsTransitiveAndOneEdit` (breadboard ← module plugged ← nothing; move breadboard 10 mm via `moveParts(carriedParts ∪ {bb})` as one `.replace`: module moved, attached wire end moved, free wire end not; one undo restores); `deletingPartDetachesWiresInOneEdit` (remove + replace in one `perform` sequence wrapped by a helper `DocumentModel.perform(_ edits: [SceneEdit], actionName:)` — add this batch API: one undo step for several edits); `legEndStaysWhenPlugged` (moving resistor body whose leg is plugged elsewhere keeps that leg end).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement; add `DocumentModel.perform(_ edits: [SceneEdit], actionName: String)` (applies in order, registers one undo that applies inverses in reverse; skips if all no-op; one `onChange`).
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): part geometry, plugging, carry-along, wire reconciliation`.

### Task 3: NetKit

**Files:**
- Modify: `Packages/FlyingSketchKit/Package.swift` (target `NetKit` → SketchCore; test target; platforms add `.macOS(.v26)`)
- Create: `Sources/NetKit/Nets.swift`
- Test: `Tests/NetKitTests/NetTests.swift`

**Interfaces:**
- Produces: `public struct Net: Hashable, Sendable { var id: Int; var name: String; var members: Set<ConnectorRef>; var wires: Set<ObjectID> }`; `public func nets(in doc: SketchDocument) -> [Net]` — union-find over connectors from wires with both ends attached (and a wire with one attached end still belongs to that connector's net), `contacts(in:)`, and each part's `buses`. Only nets with ≥ 2 members or ≥ 1 wire are returned. Naming: if all member pins with a role share `power`/`ground` and their connector names agree (e.g. `GND`, `3V3`, `5V`), name = that connector name; else `N1`, `N2`… in stable order (sorted by smallest `(part label, connector name)`). `public func net(containing ref: ConnectorRef, in nets: [Net]) -> Net?`.

- [ ] **Step 1: Write failing tests** — `wireJoinsTwoPins`; `breadboardBusJoinsColumn` (two parts plugged into the same 5-hole column → one net, no wire); `chainedWiresMerge`; `groundNetNamedGND`; `unconnectedPinsHaveNoNet`; `stableNamesAcrossRecompute`; performance: `netsFor500PartsUnder50ms` (fixture with 500 resistors on breadboards, measure with `ContinuousClock`).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(nets): NetKit net computation`.

### Task 4: ZIP reader (PartsKit)

**Files:**
- Modify: `Package.swift` (target `PartsKit` → SketchCore; test target with resources `Tests/PartsKitTests/Fixtures/`)
- Create: `Sources/PartsKit/Zip/ZipReader.swift`
- Test: `Tests/PartsKitTests/ZipReaderTests.swift`, fixtures `stored.zip`, `deflated.zip` (generate with `/usr/bin/zip` during the task and commit them)

**Interfaces:**
- Produces: `public struct ZipReader { init(data: Data) throws; var entryNames: [String]; func data(for name: String) throws -> Data }`; `public enum ZipError: Error, Equatable { case notAZip, unsupportedMethod(UInt16), corrupt(String), tooLarge(String), unsafePath(String) }`. Parses the end-of-central-directory + central directory; methods 0 (stored) and 8 (deflate via `Compression` `COMPRESSION_ZLIB` raw deflate); verifies CRC-32; rejects entries with uncompressed size > 20 MB, total > 100 MB, names containing `..` or starting with `/`; no ZIP64, no encryption (→ `unsupportedMethod`/`corrupt`).

- [ ] **Step 1: Write failing tests** — `readsStoredAndDeflated` (contents equal originals); `rejectsHostileArchives` (truncated data → `.corrupt`/`.notAZip`; entry name `../evil` → `.unsafePath`; declared size 1 GB → `.tooLarge`; bad CRC → `.corrupt`).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(parts): minimal safe ZIP reader`.

### Task 5: SVG geometry

**Files:**
- Create: `Sources/PartsKit/SVG/SVGGeometry.swift`, `SVGTransform.swift`, `SVGPathBounds.swift`
- Test: `Tests/PartsKitTests/SVGGeometryTests.swift`, fixtures `connectors.svg`

**Interfaces:**
- Produces: `public struct SVGGeometry { init(data: Data) throws; var sizeMM: Vec2; func centerMM(ofElement id: String) -> Vec2?; func lineMM(ofElement id: String) -> (Vec2, Vec2)? }`; `public enum SVGError: Error, Equatable { case notSVG, missingSize, unsupported(String) }`.
  - Size: root `width`/`height` with units `in`, `mm`, `cm`, `px` (90 dpi, Fritzing's legacy), `pt`, or unitless (= px); missing → `.missingSize`. `viewBox` maps user units to that size.
  - Transforms on any ancestor: `matrix`, `translate`, `scale`, `rotate(a[,cx,cy])`, `skewX/Y`; nested `<g>`, `<svg>` (nested viewport ignored except transform), `<use>` not supported (element found via `use` → nil).
  - Element bounds: `rect`, `circle`, `ellipse`, `line`, `polygon`, `polyline`, `path` (M/L/H/V/C/S/Q/T/A/Z, absolute + relative; curves bounded by control points — acceptable over-approximation); center = center of transformed bounding box.
  - `lineMM` for `<line>` (legs): transformed endpoints.

- [ ] **Step 1: Write failing tests** — `inchesAndViewBox` (`width="1in" viewBox="0 0 1000 1000"`, rect at 500,500 size 10 → center (12.7, 12.7) mm ± 1e-6); `nestedTransforms` (group translate + rotate 90 + scale); `pathBounds` (relative arc path center); `pxUses90dpi`; `missingConnectorGeometryIsAnError` lives in Task 6 (here: `centerMM` of unknown id → nil).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement with `XMLParser` (collect id → element + accumulated transform in one pass).
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(parts): SVG geometry for connector positions`.

### Task 6: Fritzing `.fzp` / `.fzpz` → PartDefinition

**Files:**
- Create: `Sources/PartsKit/Fritzing/FzpParser.swift`, `FzpzImporter.swift`, `PartHash.swift`
- Test: `Tests/PartsKitTests/FzpParserTests.swift`, fixtures: a real resistor `.fzp` + breadboard SVG, a real breadboard `.fzp` + SVG, a real sensor module `.fzpz` (copied from fritzing-parts at the pinned commit of Task 7 — record source path + commit in `Fixtures/SOURCES.md`)

**Interfaces:**
- Consumes: Tasks 1, 4, 5.
- Produces:
  - `public struct FzpParser { static func parse(fzp: Data, breadboardSVG: Data, svgFileName: String) throws -> PartDefinition }` — `libraryID` = fzp `moduleId`; title, family (property `family`), `labelPrefix` (`<label>`, default "U"), tags, properties (all `<property>`), size = SVG size; connectors: `<connector id name type>` + `<description>`, position = `SVGGeometry.centerMM(svgId)` of the breadboard view `<p svgId=… legId=…>`; `legId` present → `LegSpec` (origin = line start, defaultEnd = line end, color from the SVG `stroke` attribute or default gray, width = stroke-width in mm or 0.6); type `male`/`female`/`pad` (unknown → male). Buses from `<buses><bus><nodeMember connectorId>`. Role heuristic from connector name: `GND`/`VSS` → ground; `3V3`/`3.3V`/`5V`/`VIN`/`VCC`/`VDD` → power; `SDA` → i2cSDA; `SCL` → i2cSCL; `MOSI/MISO/SCK/SCLK/CS` → spi; `TX/RX` (incl. `TXD`, `U0TXD`) → uart; `GPIO\d+`/`D\d+`/`IO\d+` → digital; `A\d+`/`ADC` → analog; else nil.
  - `PartHash.versionHash(definitionWithoutHash: PartDefinition, graphic: Data) -> String` — SHA-256 hex (first 16 chars) of canonical JSON (`.sortedKeys`) + graphic bytes.
  - `public struct FzpzImporter { static func importPart(_ data: Data) throws -> (definition: PartDefinition, graphic: Data) }` — finds the single `*.fzp` entry, resolves the breadboard SVG by the fzp's `breadboardView` layer `image` path (Fritzing names it `svg.breadboard.<file>` inside fzpz).
  - `public enum PartImportError: Error, Equatable { case noFzp, multipleFzp, missingBreadboardSVG(String), missingConnectorGeometry(String), invalidFzp(String) }`.

- [ ] **Step 1: Write failing tests** — `parsesResistorWithLegs` (2 connectors, both legged, leg length ≈ SVG line length); `parsesBreadboardBuses` (bus count equals fzp `<bus>` count; a row's 5 holes in one bus); `importsFzpzModule` (connector names and count match fzp); `missingConnectorGeometryIsAnError` (fzp references `connector3pin` absent from SVG → `.missingConnectorGeometry("connector3")`); `importRejectsBrokenParts` (no fzp / two fzp / missing svg); `hashChangesWithGraphic`; `rolesFromNames` (table test).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(parts): Fritzing fzp/fzpz import`.

### Task 7: Bundled catalog (builder CLI + generated catalog)

**Files:**
- Modify: `Package.swift` (executable target `catalog-builder` → PartsKit, macOS)
- Create: `Packages/FlyingSketchKit/Sources/catalog-builder/main.swift`, `Tools/fetch-parts.sh`, `Tools/catalog-manifest.json`, generated `App/Catalog/catalog.json`, `App/Catalog/parts/*.json`, `App/Catalog/graphics/*`, `App/Catalog/ATTRIBUTION.md`, hand-authored parts under `Tools/custom-parts/` if needed
- Modify: `project.yml` (`App/Catalog` as a folder resource), `.gitignore` (`Vendor/`)
- Test: `Tests/PartsKitTests/CatalogTests.swift`

**Interfaces:**
- Produces:
  - `Tools/fetch-parts.sh` clones `https://github.com/fritzing/fritzing-parts` and `https://github.com/adafruit/Fritzing-Library` into `Vendor/` at commits pinned in the script (pin current `HEAD` at implementation time; record SHAs).
  - `Tools/catalog-manifest.json`: list of `{ "source": "fritzing-parts"|"adafruit"|"custom", "fzp": "<path>", "id": "<catalog id>" }` covering at minimum: ESP32-S3-DevKitC-1, ESP32-C3-DevKitM-1, full breadboard, half breadboard, resistor, LED (5 mm), push button, potentiometer, DHT22, BME280 breakout, HC-SR04, PIR sensor (HC-SR501), photoresistor (LDR).
  - `catalog-builder <manifest> <vendorDir> <customDir> <outDir>` → `outDir/catalog.json` = `[{ id, title, family, tags, file }]`, `outDir/parts/<id>.json` = `PartDefinition`, `outDir/graphics/<graphicAsset>`, `outDir/ATTRIBUTION.md` (source, path, commit, fzp `<author>`, license CC-BY-SA 3.0). Deterministic output (sorted keys, stable order).
  - If a minimum-set part is missing or broken in both sources, author it under `Tools/custom-parts/<id>/` (fzp + breadboard SVG, MIT-licensed by us) — required for the ESP32 boards if no source matches exactly.
  - Board pinouts **must** match Espressif's user guides (ESP32-S3-DevKitC-1: 2 × 22-pin headers J1/J3 = 44 pins; ESP32-C3-DevKitM-1: 2 × 15-pin headers J1/J3 = 30 pins). The implementer fetches the official pin tables (docs.espressif.com user guides) and records them as `Tests/PartsKitTests/Fixtures/esp32s3-devkitc1-pins.json` / `esp32c3-devkitm1-pins.json` (header, pin number, name) with the source URL.

- [ ] **Step 1: Write failing tests** — `catalogContainsMinimumSet` (loads generated `App/Catalog`; every manifest id present; every part decodes); `esp32BoardsMatchEspressifPinout` (connector names per header/order equal the recorded fixture; counts 44 and 30); `attributionListsEveryPart`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement builder + script; run `Tools/fetch-parts.sh` then `swift run catalog-builder Tools/catalog-manifest.json Vendor Tools/custom-parts App/Catalog`; commit generated output.
- [ ] **Step 4:** Run tests. Expected: PASS. Run app build. Expected: success.
- [ ] **Step 5:** Commit `feat(parts): bundled Fritzing-derived catalog with ESP32-S3/C3 boards`.

### Task 8: Parts library

**Files:**
- Create: `Sources/PartsKit/Library/PartsLibrary.swift`, `PersonalLibraryStore.swift`
- Modify: `project.yml` + `App/FlyingSketch.entitlements` (iCloud container `iCloud.com.flyingturtle.flyingsketch`, CloudDocuments)
- Test: `Tests/PartsKitTests/PartsLibraryTests.swift`

**Interfaces:**
- Produces:
  - `public struct LibraryPart: Hashable, Sendable { var definition: PartDefinition; var graphic: Data; var source: Source /*bundled, personal*/ }`
  - `public actor PartsLibrary { init(bundledCatalogURL: URL, personalStore: PersonalLibraryStore); func allParts() async -> [LibraryPart]; func search(_ query: String) async -> [LibraryPart] /*case-insensitive over title, family, tags, properties values; empty query = all*/; func part(libraryID: String) async -> LibraryPart? /*newest: personal wins over bundled*/; func importFzpz(_ data: Data) async throws -> LibraryPart; func save(_ part: LibraryPart) async throws }`
  - `public struct PersonalLibraryStore: Sendable { init(rootURL: URL); static func defaultRoot() -> URL /*iCloud container Documents/Parts if available, else Application Support/Parts*/; func load() throws -> [LibraryPart]; func write(_ part: LibraryPart) throws }` — one directory per `libraryID` containing `part.json` + graphic; writes atomically; directory names sanitized (no `/`, `..`).

- [ ] **Step 1: Write failing tests** — `searchMatchesTitleFamilyTags`; `personalOverridesBundledByLibraryID`; `importFzpzPersists` (temp root; reload store → part present); `storeSanitizesIDs` (`libraryID` "../x" stays inside root).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. iCloud: `FileManager.default.url(forUbiquityContainerIdentifier:)` off the main actor; fallback when nil.
- [ ] **Step 4:** Run. Expected: PASS. App builds with the entitlement (`-allowProvisioningUpdates`).
- [ ] **Step 5:** Commit `feat(parts): bundled + personal parts library`.

### Task 9: Rendering parts, legs and wires

**Files:**
- Modify: `Package.swift` (SwiftDraw dependency for CanvasUI), `Sources/CanvasUI/Rendering/ObjectLayerFactory.swift`, `SceneRenderer.swift`
- Create: `Sources/CanvasUI/Rendering/PartRasterCache.swift`
- Test: `Tests/CanvasUITests/PartRenderingTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 2.
- Produces:
  - `ObjectLayerFactory.prepare(document:)` replaces `prepare(assets:)` (factory needs `parts` + `assets`); renderer passes the document. Keep behavior for existing kinds.
  - Part layer: container `CALayer` with the rasterized graphic (SwiftDraw `SVG(data:)` → `rasterize(size:scale:)`; PNG via `UIImage`) sized to `size × pointsPerMillimetre × zoom`, rotated by quarterTurns; raster scale = view scale capped so the backing store ≤ **4096 px** per edge (same rule as text); `PartRasterCache` keyed by `(graphicAsset, scaleBucket)` where scale buckets are powers of 2; LRU with max 64 MB.
  - Legs: `CAShapeLayer` lines from `localToWorld(leg.origin)` to the leg end, round caps, leg color/width — drawn above the graphic.
  - Wire layer: `CAShapeLayer` polyline start → bends → end, round joins/caps, color, width in mm; free ends drawn with a small open circle (r = 0.6 mm).
  - Bounds for culling come from `bounds(of:in:)`.
  - Unknown definition key → placeholder: dashed 10 mm square with the label.

- [ ] **Step 1: Write failing tests** — `partLayerSizedInView` (definition 20×10 mm at zoom 2 → layer bounds 20·6.3·2 × 10·6.3·2 pt ± 0.5); `rasterScaleCapped` (zoom 32 big part → backing ≤ 4096 px); `rotatedPartSwapsExtent`; `wireLayerPathFollowsBends`; `missingDefinitionShowsPlaceholder`; `rasterCacheReusesBucket`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(canvas): render parts, legs and wires`.

### Task 10: Placing, moving, rotating, labelling and editing parts

**Files:**
- Create: `Sources/CanvasUI/Parts/CanvasView+Parts.swift`, `App/Views/PartsLibraryView.swift`, `App/Views/PartInspectorView.swift`
- Modify: `Sources/CanvasUI/Selection/CanvasView+Selection.swift` (move/delete/duplicate/copy/paste), `Clipboard.swift`, `App/Views/SketchEditorView.swift`, `App/Views/ToolPalette.swift`, `App/FlyingSketchApp.swift` (create one shared `PartsLibrary`)
- Test: `Tests/CanvasUITests/PartPlacementTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 2, 8, 9.
- Produces:
  - `public func placePart(_ part: LibraryPart)` on `CanvasView`: embeds definition (`setDefinitions` if key missing) + graphic asset (`addAssets`, asset name = `graphicAsset`) and inserts a `PartInstance` at the viewport center (plug-snapped if possible), label = `labelPrefix` + next free number among parts with that prefix (`R1`, `R2`…; prefix "" → no label), properties = definition properties; all in one `perform([…], actionName: "Add Part")`; selects it.
  - Moving: when the selection contains parts, `endMove` uses `moveParts(selected ∪ carriedParts(selected), …)` and, on release, applies `plugSnapOffset` to the moved set (excluding moved parts) — one edit "Move". Move preview shows carried parts and attached wire ends moving.
  - `public func rotateSelectedParts(clockwise: Bool)` — one edit "Rotate".
  - Delete: `deleteSelection` uses `removeParts` so attached wires detach in the same edit.
  - Duplicate / copy-paste: parts keep their definition (clipboard payload gains `definitions: [String: PartDefinition]` + their graphic assets); pasted wires keep attachments only if their part is also pasted (ids remapped), otherwise become free; labels renumbered on paste/duplicate.
  - `public func updatePartProperties(_ id: ObjectID, label: String, properties: [String: String])` — one edit "Edit Part".
  - Edit menu gains "Rotate ↻", "Rotate ↺" for part selections.
  - App: palette button "Parts" (SF Symbol `cpu`) opens `PartsLibraryView` (sheet: search field, list grouped by family with title + thumbnail rendered from the graphic, "Import .fzpz…" via `fileImporter` for `UTType(filenameExtension: "fzpz")`; tap → `placePart` and dismiss). Selecting exactly one part shows an "Inspector" button → `PartInspectorView` popover (label field, editable property rows; Save → `updatePartProperties`).

- [ ] **Step 1: Write failing tests** — `placePartEmbedsDefinitionOnce` (two placements → one `parts` entry, labels R1, R2, one undo each); `moveBreadboardCarriesPlugged`; `dropSnapsIntoHoles` (drop resistor 0.6 mm off → contacts == 2); `deleteDetachesWires`; `pasteRemapsWireAttachments`; `rotateUpdatesAttachedWireEnds`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS. App simulator build succeeds.
- [ ] **Step 5:** Commit `feat(parts): place, move, rotate, label and edit parts; library sheet`.

### Task 11: Wire tool

**Files:**
- Create: `Sources/CanvasUI/Tools/WireController.swift`
- Modify: `Tool.swift` (`ToolKind.wire`), `CanvasView.swift` (routing), `App/Views/ToolPalette.swift` (wire button, SF Symbol `point.topleft.down.to.point.bottomright.curvepath`)
- Test: `Tests/CanvasUITests/WireControllerTests.swift`

**Interfaces:**
- Produces:
  - `final class WireController { init(model: DocumentModel); func connector(near world: Vec2, radius: Double) -> (ConnectorRef, Vec2)?; func begin(at world: Vec2, radius: Double); func addBend(at world: Vec2); func moveRubberBand(to world: Vec2) -> [Vec2] /*preview polyline*/; func finish(at world: Vec2, radius: Double); func cancel() }`.
  - Interaction: with the wire tool, touch-down starts a wire (snapped to the nearest connector within the connector hit radius, else free point); dragging shows a rubber band; lifting over a connector finishes and inserts the wire ("Add Wire"); lifting elsewhere adds a bend point and keeps the wire open; the next touch-down continues from there; a tap on the last bend point, tool change, or two-finger tap finishes it as a free end (if it has ≥ 2 points). Color = `toolState.color`, width 0.65 mm.
  - Endpoint editing: with the wire tool, touch-down on an existing wire end (within hit radius) drags that end; release over a connector attaches, elsewhere detaches; one edit "Move Wire End".
  - Live preview drawn in view space on a dedicated layer (same style as committed wire).

- [ ] **Step 1: Write failing tests** — `wireBetweenTwoConnectorsAttachesBothEnds`; `bendsAreKeptInOrder`; `freeEndedWire`; `singlePointWireIsNotInserted`; `dragEndReattaches`; `dragEndDetaches`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(canvas): wire tool with bends and endpoint editing`.

### Task 12: Bendable legs

**Files:**
- Create: `Sources/CanvasUI/Parts/LegController.swift`
- Modify: `CanvasView.swift` (routing: with lasso tool or finger in selection mode, touch-down on a leg end handle of a selected part drags the leg)
- Test: `Tests/CanvasUITests/LegControllerTests.swift`

**Interfaces:**
- Produces: `final class LegController { init(model: DocumentModel); func begin(part: ObjectID, connector: String); func move(to world: Vec2); func end(); func cancel() }` — end snaps to a female connector within 1.0 mm (exact position) else stays where released; one edit "Bend Leg"; attached wire ends on that connector follow. Leg end handles (r = 1 mm circles) drawn for selected legged parts.

- [ ] **Step 1: Write failing tests** — `legSnapsIntoHole` (contacts include it); `legDragUpdatesAttachedWire`; `cancelLeavesLegUnchanged`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(canvas): bendable legs`.

### Task 13: Net highlight and pin info

**Files:**
- Create: `Sources/CanvasUI/Parts/NetHighlight.swift`
- Modify: `Package.swift` (CanvasUI → NetKit), `CanvasView.swift`, `SceneRenderer.swift`, `App/Views/SketchEditorView.swift`
- Test: `Tests/CanvasUITests/NetHighlightTests.swift`

**Interfaces:**
- Produces:
  - `public struct PinInfo: Equatable { var partLabel: String; var connectorName: String; var role: PinRole?; var netName: String?; var memberCount: Int }` and `@Observable public final class NetHighlightState { public var info: PinInfo?; var net: Net? }` exposed as `CanvasView.netHighlight`.
  - A tap (finger in selection mode, or Pencil with lasso tool) within the connector hit radius of a connector highlights its net: rings (r = 1.2 mm, accent color) on all member connectors and a glow (wider translucent stroke) on member wires; tap elsewhere clears. Nets recomputed on `documentChanged` (cached; only when objects/parts changed).
  - App shows a compact card under the palette while `info != nil`: "R1 · leg1 — N3 (4 pins)" / "U1 · GPIO4 · digital — N3 (4 pins)".

- [ ] **Step 1: Write failing tests** — `tapOnPinHighlightsNet` (members of the wired net highlighted, info filled); `highlightClearsOnEmptyTap`; `highlightUpdatesAfterUndo` (undo the wire → net shrinks / info updates).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(canvas): net highlight and pin info`.

### Task 14: Library versions vs documents

**Files:**
- Create: `Sources/CanvasUI/Parts/CanvasView+PartUpdates.swift`, `App/Views/PartUpdatesView.swift`
- Modify: `App/Views/SketchEditorView.swift`
- Test: `Tests/CanvasUITests/PartUpdateTests.swift`

**Interfaces:**
- Produces:
  - `public func outdatedParts(comparedTo library: [LibraryPart]) -> [(current: PartDefinition, newer: LibraryPart)]` on `CanvasView` — document definitions whose `libraryID` exists in the library with a different `versionHash`.
  - `public func updatePart(libraryID: String, to newer: LibraryPart)` — one edit "Update Part": add the newer definition + graphic, repoint every instance using an older key to the new key, reset leg ends of connectors that vanished, `reconcileWires` (wires on vanished connectors become free at their last position), remove definitions no longer referenced.
  - App: when `outdatedParts` is non-empty after opening a document, show a toolbar badge "Updates (n)" → `PartUpdatesView` list with an Update button per part.
  - Copy-paste of a part whose key already exists with a different hash in the target keeps both definitions (no automatic update).

- [ ] **Step 1: Write failing tests** — `detectsOutdatedPart`; `updateRepointsInstancesInOneEdit` (undo restores old key + wires); `vanishedConnectorFreesWire`; `pasteKeepsBothVersions`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS. Full suite + app build pass.
- [ ] **Step 5:** Install on Lars' iPad (`xcodebuild … -destination 'id=00008027-001878813EE9802E' -allowProvisioningUpdates build` + `xcrun devicectl device install app …`). **Manual check (Lars):** place ESP32-S3 board on a full breadboard, plug two resistors and an LED with stretched legs, wire 3V3/GND and a GPIO to a BME280, tap pins to see nets, move the breadboard (everything follows), rotate the LED, delete a part (wires go free), undo, close/reopen document.
- [ ] **Step 6:** Commit `feat(parts): library version detection and part updates`.
