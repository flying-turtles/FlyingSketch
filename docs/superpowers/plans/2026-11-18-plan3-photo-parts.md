# FlyingSketch Plan 3 — Photo Parts

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a top-down photo of a board with no Fritzing model into a part with real pins. The flow is photo, auto cutout (or manual trace), Pencil refine, crop/straighten, scale calibration, pins and buses, then metadata. The part is saved to the personal iCloud library, can be re-edited later, and round-trips through `.fzpz` export.

**Architecture:** A new `PhotoPartKit` target holds all pure logic. It has no UIKit, builds for iOS and macOS, and covers:
- image loading and normalization (ImageIO);
- the `MaskBitmap` ops;
- the Vision foreground cutout;
- the `PhotoPartDraft` geometry, where every point is stored in source-image pixels and one crop/rotate transform maps them to output;
- PNG rendering and `PartDefinition` building;
- an `@Observable` `StudioSession` state machine with mask undo.

`PartsKit` gains three things: studio sidecar files and delete in the personal store, a `ZipWriter`, and an `FzpzExporter`. Re-import through an `FzpzImporter` sidecar is lossless. `CanvasUI` gains a UIKit `StudioCanvasView` (image, mask overlay, zoom/pan, brush/trace/crop/scale/pin input). The app adds the studio screens and the library entry points (new, edit, export, delete). Photo parts are ordinary `PartDefinition`s with `graphicKind: .png`, so placement, rendering and updates need no changes.

**Tech Stack:** Swift 6, SwiftUI, UIKit, Vision (`VNGenerateForegroundInstanceMaskRequest`), ImageIO, CoreGraphics, CoreVideo, Observation, Swift Testing, xcodegen.

**Spec:** `docs/superpowers/specs/2026-11-18-flyingsketch-v1-design.md`. Relevant sections: Goals 3, Part definition, Parts library (personal library), and "Photo parts (PhotoPartStudio)".

## Global Constraints

Everything in the Plan 1 and Plan 2 Global Constraints still holds: iPadOS 26; Swift 6 strict concurrency; xcodegen; team `WDJPX25GFC`; bundle id `com.flyingturtle.flyingsketch`; no GPL; no `.metal`; MIT; world units are mm as `Double`. Also: the plug/contact tolerances, every user action is one undoable edit, and `onChange` is always chained.

Plan 3 adds these:

- **No new third-party dependencies.** Use Apple frameworks only.
- **`PhotoPartKit` must not import UIKit or SwiftUI** (macOS build must work). It may import Foundation, CoreGraphics, ImageIO, Vision, CoreVideo, UniformTypeIdentifiers and Observation. It depends on `SketchCore` and `PartsKit`. `StudioSession` is `@MainActor`. All other types are `Sendable` values.
- **Document format is unchanged** (`formatVersion` stays 2). A photo part is a `PartDefinition` with `graphicKind: .png`.
- **Fixed values:**

  | Value | Setting |
  |---|---|
  | Source image long edge | **≤ 2048 px**, EXIF orientation applied, 8-bit RGBA sRGB |
  | Output PNG long edge | **≤ 2048 px** |
  | Pin grid pitch | **2.54 mm**, anchored at the first pin |
  | Two-point calibration default distance | **2.54 mm** |
  | Minimum calibration point distance | **10 px** (source) |
  | Mask undo depth | **20** |
  | Brush radius | **2…200 px** (source), default **24** |
  | Straighten angle | **−45°…45°**, plus quarter turns |
  | Default connector kind | `male` |
  | Pin marker on screen | **r 1 mm** (min 10 pt) |

- **Photo-part `libraryID`:** `photo-<UUID lowercased>`. It is fixed when the part is created and reused on re-edit, so documents get "update available" through the Plan 2 mechanism.
- **Connector ids:** `connector<N>`, where N counts up from 0 in creation order and is never reused within a draft. Names must be non-empty and unique (case-insensitive), because netlists use names.
- **Personal part directory:** may hold `studio/draft.json`, `studio/source.png` and `studio/mask.png` next to `part.json` and the graphic. Their absence means the part is not re-editable.
- **Exported `.fzpz`:** contains `part.<libraryID>.fzp`, `svg.breadboard.<libraryID>.svg` (PNG embedded as a data URI, plus one transparent 0.5 mm `rect` per connector with id `connector<N>pin`), `flyingsketch.json` (the `PartDefinition`) and `flyingsketch.png`.
- **Camera permission:** `INFOPLIST_KEY_NSCameraUsageDescription` = `"Take a photo of a part to turn it into a FlyingSketch part."`
- **Commands:**
  - Package tests: `cd Packages/FlyingSketchKit && xcodebuild test -scheme FlyingSketchKit-Package -destination 'platform=iOS Simulator,id=08D1B7B4-263D-4479-8F34-C24730978306' -quiet`.
  - App build: `xcodegen generate && xcodebuild -project FlyingSketch.xcodeproj -scheme FlyingSketch -destination 'platform=iOS Simulator,id=08D1B7B4-263D-4479-8F34-C24730978306' -quiet build`.

## Review Focus

1. **Odd photos.** Inputs: a 48 MP HEIC, an EXIF-rotated JPEG, grayscale or 16-bit PNGs. Each must load upright as 8-bit RGBA with a long edge ≤ 2048, never cause an out-of-memory crash, and give a typed error on undecodable data. Test: Task 1 `normalizesOrientationSizeAndFormat`.
2. **Degenerate cutouts.** Cases: a mask erased to nothing, a trace with fewer than 3 points, a self-intersecting trace. Save must be blocked with a typed error, and a zero-size or fully transparent part is never produced. Tests: Task 1 `polygonFillEvenOdd`, Task 4 `emptyMaskIsAnError`.
3. **Re-cropping or rotating after pins exist.** Pins and calibration points must stay on the same photo features, because they are stored in source pixels. A pin that falls outside the crop must block save with an error naming that pin. Tests: Task 3 `pinsFollowCropAndRotation`, Task 4 `pinOutsideCropIsAnError`.
4. **Vision unavailable or finding nothing** (simulator, unsupported device, plain background). The studio must fall back to manual trace / whole photo with a message, never hang or crash. Test: Task 5 `cutoutFailureFallsBackToManual`.
5. **Untrusted synced or imported studio data.** Cases: a tampered `draft.json`, a mask with the wrong size, a sidecar whose definition fails validation. These must give a typed error, or "not re-editable", and must never crash. Tests: Task 6 `corruptStudioFilesAreNotEditable`, Task 7 `tamperedSidecarIsRejected`.

---

### Task 1: PhotoPartKit target, image loading, MaskBitmap

**Files:**
- Modify: `Packages/FlyingSketchKit/Package.swift` (product + target `PhotoPartKit` depending on `SketchCore` and `PartsKit`; test target `PhotoPartKitTests`)
- Create: `Sources/PhotoPartKit/Image/SourceImage.swift`, `Sources/PhotoPartKit/Mask/MaskBitmap.swift`
- Test: `Tests/PhotoPartKitTests/SourceImageTests.swift`, `MaskBitmapTests.swift`

**Interfaces:**
- Produces:
  - `public enum PhotoPartError: Error, Equatable, Sendable { case undecodableImage, emptyMask, traceTooShort, missingScale, calibrationTooShort, invalidDistance, partTooLarge, pinOutside(String), emptyPinName(String), duplicatePinName(String), unknownBusMember(String), pinInTwoBuses(String), emptyTitle, maskSizeMismatch, cutoutUnavailable, noForeground }`. Later tasks add no cases: every error case is declared here.
  - `public struct SourceImage: Sendable`:
    - `let image: CGImage` (8-bit RGBA premultiplied, sRGB, upright);
    - `var pixelSize: PixelSize`;
    - `static let maxEdge = 2048`;
    - `static func load(_ data: Data) throws(PhotoPartError) -> SourceImage`, using `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailWithTransform`, `ThumbnailFromImageAlways` and `MaxPixelSize = maxEdge`, then redrawn into an RGBA context;
    - `func pngData() -> Data`.
  - `public struct PixelSize: Hashable, Codable, Sendable { var width: Int; var height: Int }`.
  - `public struct MaskBitmap: Hashable, Sendable`:
    - `let width, height: Int`;
    - `var bytes: [UInt8]`, row-major, 0 or 255, origin top-left;
    - `init(width:height:filled: Bool)`;
    - `func value(at: Vec2) -> Bool`;
    - `mutating func stroke(_ points: [Vec2], radius: Double, add: Bool)`, which stamps discs every `radius/2` along the segments;
    - `mutating func fillPolygon(_ points: [Vec2]) throws(PhotoPartError)`, which replaces the whole mask using the even-odd scanline rule and throws `.traceTooShort` when there are fewer than 3 points;
    - `mutating func formUnion(_ other: MaskBitmap) throws(PhotoPartError)`, which throws `.maskSizeMismatch` when sizes differ;
    - `var boundingBox: PixelRect?`, nil when empty;
    - `func pngData() -> Data`, 8-bit gray;
    - `static func decode(png: Data, expected: PixelSize) throws(PhotoPartError) -> MaskBitmap`, which thresholds at 128 and throws `.maskSizeMismatch` when the size differs.
  - `public struct PixelRect: Hashable, Sendable { var minX, minY, maxX, maxY: Int }`. Bounds are inclusive.

- [ ] **Step 1: Write failing tests**
  - `normalizesOrientationSizeAndFormat`. Inputs: 4000×1000 JPEG with EXIF orientation 6 → 512×2048, top-left pixel is the source's bottom-left colour. 16-bit gray PNG → RGBA 8-bit. Garbage bytes → `.undecodableImage`.
  - `strokeAddsAndErases`: a 100×100 empty mask, stroke (10,50)→(90,50) r 5 → (50,50) is set and (50,60) is not; erase stroke clears (50,50).
  - `polygonFillEvenOdd`: square fills its interior; a bow-tie leaves the centre crossing cell consistent with even-odd; 2 points → `.traceTooShort`.
  - `boundingBoxAndEmpty`.
  - `maskPNGRoundTrip`, including the wrong size → `.maskSizeMismatch`.
- [ ] **Step 2:** Run the package tests. Expected: FAIL (module missing).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS. All earlier tests still pass.
- [ ] **Step 5:** Commit `feat(photo): PhotoPartKit target, source image loading, mask bitmap`.

### Task 2: Vision foreground cutout

**Files:**
- Create: `Sources/PhotoPartKit/Cutout/ForegroundCutout.swift`
- Test: `Tests/PhotoPartKitTests/ForegroundCutoutTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces:
  - `public protocol CutoutProviding: Sendable { func instances(in image: SourceImage) async throws(PhotoPartError) -> [MaskBitmap] }`.
  - `public struct VisionCutout: CutoutProviding`. It runs `VNGenerateForegroundInstanceMaskRequest` off the main actor, then `generateScaledMaskForImage(forInstances: [i], from: handler)` for each instance, converted to `MaskBitmap`. A request failure → `.cutoutUnavailable`. Zero instances → `.noForeground`. Results are sorted by area, largest first.
  - `static func mask(from buffer: CVPixelBuffer) -> MaskBitmap`, internal and testable. It accepts `kCVPixelFormatType_OneComponent32Float` and `OneComponent8`, with threshold 0.5.
  - `public func instanceIndex(at point: Vec2, in masks: [MaskBitmap]) -> Int?`: the first mask containing `point`.

- [ ] **Step 1: Write failing tests**
  - `maskFromFloatBuffer`: a hand-built 4×2 float buffer [0,1,0.4,0.6,…] → expected bits.
  - `maskFromByteBuffer`.
  - `instanceIndexPicksContainingMask`.
  - `visionOnSyntheticImageIsTyped`: a red disc on white. The result is either non-empty instances whose union covers the disc centre, or a thrown `.cutoutUnavailable` / `.noForeground`. It must never crash.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(photo): Vision foreground instance cutout`.

### Task 3: Draft model and geometry

**Files:**
- Create: `Sources/PhotoPartKit/Draft/PhotoPartDraft.swift`, `Sources/PhotoPartKit/Draft/DraftGeometry.swift`
- Test: `Tests/PhotoPartKitTests/DraftGeometryTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces:
  - `public struct CropSpec: Hashable, Codable, Sendable`:
    - `var center: Vec2` (source px);
    - `var size: Vec2` (px, in the rotated frame);
    - `var angle: Double` (radians, −π/4…π/4);
    - `var quarterTurns: Int` (0…3, clockwise);
    - `static func full(_ s: PixelSize) -> CropSpec`.
  - `public enum ScaleSpec: Hashable, Codable, Sendable { case twoPoints(Vec2, Vec2, mm: Double) /*source px*/, width(mm: Double) /*output crop width*/ }`.
  - `public struct DraftPin: Hashable, Codable, Sendable { var id: String; var name: String; var description: String; var kind: ConnectorKind; var role: PinRole?; var position: Vec2 /*source px*/ }`.
  - `public struct PartMetadata: Hashable, Codable, Sendable { var title, family, labelPrefix: String; var tags: [String]; var properties: [String: String] }`. Defaults: family `"Photo parts"`, labelPrefix `"U"`.
  - `public struct PhotoPartDraft: Hashable, Codable, Sendable`, with these members:
    - `var libraryID: String`;
    - `var sourceSize: PixelSize`;
    - `var crop: CropSpec`;
    - `var scale: ScaleSpec?`;
    - `var pins: [DraftPin]`;
    - `var buses: [[String]]`;
    - `var gridSnap: Bool` (default true);
    - `var nextPinNumber: Int`;
    - `var metadata: PartMetadata`;
    - `init(sourceSize:)`, which sets a new `photo-<uuid>` id and a full crop;
    - `func outputSize() -> Vec2` (crop px; swapped for odd quarter turns);
    - `func toOutput(_ p: Vec2) -> Vec2`;
    - `func toSource(_ p: Vec2) -> Vec2`;
    - `func mmPerPixel() throws(PhotoPartError) -> Double`, where two points closer than 10 px → `.calibrationTooShort`, mm ≤ 0 or non-finite → `.invalidDistance`, and nil scale → `.missingScale`;
    - `mutating func addPin(atOutput p: Vec2) -> String`, which returns the id, names the pin `"P<n+1>"`, and grid-snaps when `gridSnap` is set and a first pin exists;
    - `mutating func movePin(_ id: String, toOutput p: Vec2)`, which also snaps, except when the pin moved is the anchor (first pin);
    - `mutating func removePin(_ id: String)`, which also removes it from buses and drops buses with fewer than 2 members.
  - `public func snapToPinGrid(_ outputPoint: Vec2, anchor: Vec2, mmPerPixel: Double) -> Vec2`. It rounds the anchor-relative offset to multiples of 2.54 mm on the output axes. When no scale exists yet, snapping is skipped.
  - `toOutput`: translate by −center, rotate by −(angle + quarterTurns·π/2), then translate by +outputSize/2. `toSource` is its exact inverse.

- [ ] **Step 1: Write failing tests**
  - `identityCropMapsPointsUnchanged`.
  - `quarterTurnSwapsOutputSize`: 200×100 with 1 turn → 100×200; source (0,0) → output (100,0).
  - `pinsFollowCropAndRotation`: add a pin, change the crop centre/angle → `toOutput(pin.position)` lands on the same feature after re-mapping; round trip `toSource(toOutput(p)) ≈ p` within 1e-9.
  - `twoPointCalibration`: points 254 px apart, 25.4 mm → 0.1 mm/px; 5 px apart → `.calibrationTooShort`; 0 mm → `.invalidDistance`.
  - `gridSnapAnchoredAtFirstPin`: 0.1 mm/px, first pin at (10,10), second tapped at (36,11) → (35.4,10).
  - `removePinCleansBuses`.
  - `draftCodableRoundTrip`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(photo): draft model with crop, calibration and pin grid`.

### Task 4: Render and build the part

**Files:**
- Create: `Sources/PhotoPartKit/Build/PhotoPartBuilder.swift`
- Test: `Tests/PhotoPartKitTests/PhotoPartBuilderTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3; `PartHash.versionHash`, `LibraryPart`, `PartDefinition.validate()` (Plan 2).
- Produces:
  - `public enum PhotoPartBuilder`:
    - `static let maxOutputEdge = 2048`;
    - `static func render(source: SourceImage, mask: MaskBitmap, draft: PhotoPartDraft) throws(PhotoPartError) -> Data`. It draws the source and the mask through the crop transform into the output context, multiplies alpha by the mask, and downscales so the long edge is ≤ 2048. An empty mask, or a mask with no pixel inside the crop, → `.emptyMask`.
    - `static func validate(_ draft: PhotoPartDraft) throws(PhotoPartError)`. It checks, in this order: an empty/whitespace title → `.emptyTitle`; scale (Task 3 errors); pins outside `[0, outputSize]` → `.pinOutside(name)`; empty name → `.emptyPinName(id)`; duplicate names (case-insensitive) → `.duplicatePinName(name)`; bus members → `.unknownBusMember` / `.pinInTwoBuses`; size mm > `PartDefinition.maxExtent` → `.partTooLarge`.
    - `static func build(source:mask:draft:) throws(PhotoPartError) -> LibraryPart`. It runs validate, then render, then builds the definition:
      - `size` = `outputSize() × mmPerPixel`;
      - each connector position = `toOutput(pin) × mmPerPixel`;
      - kind, role, name and description come from the pin;
      - buses and metadata come from the draft;
      - `graphicKind .png`, `versionHash` from `PartHash`, `graphicAsset "part-<hash>.png"`, `source .personal`;
      - finally `validate()`.

- [ ] **Step 1: Write failing tests**
  - `rendersMaskedCrop`: 100×50 red source, mask = left half, full crop → output 100×50, alpha 255 at (25,25), 0 at (75,25).
  - `quarterTurnRenderSwapsDimensions`.
  - `outputIsCappedAt2048`.
  - `emptyMaskIsAnError`.
  - `definitionUsesMillimetres`: 0.1 mm/px, crop 500×300 → size 50×30, pin at output (100,100) → connector (10,10).
  - `pinOutsideCropIsAnError`: names the pin.
  - `duplicatePinNamesRejected`: "GND" and "gnd".
  - `versionHashChangesWithPins`.
  - `builtPartIsValid`: `definition.validate()` passes; graphic decodes as a PNG of the reported size.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(photo): render masked PNG and build part definition`.

### Task 5: StudioSession state machine

**Files:**
- Create: `Sources/PhotoPartKit/Studio/StudioSession.swift`
- Test: `Tests/PhotoPartKitTests/StudioSessionTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `public enum StudioStep: Int, CaseIterable, Sendable { case cutout, refine, crop, scale, pins, details }`.
  - `public enum CutoutState: Equatable, Sendable { case idle, running, choosing(count: Int), done, failed(PhotoPartError) }`.
  - `@MainActor @Observable public final class StudioSession`, with these members:
    - `init(source: SourceImage, cutout: CutoutProviding, draft: PhotoPartDraft? = nil, mask: MaskBitmap? = nil)`. With no mask, it starts with a full mask.
    - `private(set) var source: SourceImage`.
    - `var draft: PhotoPartDraft`.
    - `private(set) var mask: MaskBitmap`.
    - `var step: StudioStep`.
    - `private(set) var cutoutState: CutoutState`.
    - `private(set) var instances: [MaskBitmap]`.
    - `var brushRadius: Double` (default 24, clamped 2…200).
    - `var brushAdds: Bool`.
    - `func runAutoCutout() async`. It sets `running`, then: on 1 instance, applies it and goes to `done`; on more than 1, goes to `choosing(count:)`; on an error, goes to `failed(e)` and leaves the mask unchanged.
    - `func chooseInstance(at sourcePoint: Vec2)`, which picks via `instanceIndex`.
    - `func chooseAllInstances()`.
    - `func useWholePhoto()`.
    - `func applyTrace(_ sourcePoints: [Vec2]) throws(PhotoPartError)`.
    - `func applyBrush(_ sourcePoints: [Vec2])`. One call is one undo step.
    - `func undoMask()`, `func redoMask()`, `var canUndoMask`, `var canRedoMask`. Depth is 20. Every mask change pushes a step.
    - `var blockingError: PhotoPartError?`. It is `PhotoPartBuilder.validate(draft)`, or `.emptyMask` when `mask.boundingBox == nil`.
    - `func build() throws(PhotoPartError) -> LibraryPart`.
    - `func studioFiles() -> StudioFiles`.
  - `public struct StudioFiles: Sendable, Equatable { var draft: PhotoPartDraft; var sourcePNG: Data; var maskPNG: Data }`, with these members:
    - `func encoded() throws -> [String: Data]`, keys `draft.json`, `source.png` and `mask.png`;
    - `static func decode(_ files: [String: Data]) throws(PhotoPartError) -> (SourceImage, MaskBitmap, PhotoPartDraft)`, which validates the mask size and the draft's `sourceSize` against the source and maps any failure to a `PhotoPartError`.

- [ ] **Step 1: Write failing tests.** Use a `FakeCutout` that returns fixed masks or throws.
  - `singleInstanceAppliesDirectly`.
  - `multipleInstancesAskToChoose` (then `chooseInstance` applies the one under the point).
  - `cutoutFailureFallsBackToManual`: state `failed(.cutoutUnavailable)`, mask still full, `applyTrace` works.
  - `brushUndoRedoDepth20`: 25 strokes → only 20 undoable.
  - `blockingErrorTracksDraft`: no title → `.emptyTitle`; after title and scale → nil.
  - `studioFilesRoundTrip`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(photo): studio session with cutout flow and mask undo`.

### Task 6: Personal library — studio files and delete

**Files:**
- Modify: `Sources/PartsKit/Library/PersonalLibraryStore.swift`, `Sources/PartsKit/Library/PartsLibrary.swift`
- Test: `Tests/PartsKitTests/PartsLibraryTests.swift`

**Interfaces:**
- Consumes: Plan 2 store and library.
- Produces:
  - `PersonalLibraryStore.write(_ part: LibraryPart, studio: [String: Data]? = nil) throws`. The studio files go in `studio/` inside the same atomic temp-dir swap. Names must match `^[a-z]+\.(json|png)$`, else `PersonalLibraryError.invalidStudioFile(name)`, a new case. When `studio` is nil, an existing `studio/` folder is dropped.
  - `func studioFiles(forLibraryID: String) throws -> [String: Data]?`. It returns nil when there is no folder. iCloud placeholders trigger a download and return nil. It reads only the three allowed names, each ≤ 20 MB.
  - `func delete(libraryID: String) throws`. It verifies the directory is inside the root and uses `FileManager.removeItem`.
  - `LibraryPart` gains `public var isEditable: Bool`, set by `load()` when `studio/draft.json` exists. It defaults to false, and existing inits are unchanged.
  - `PartsLibrary` gains `save(_ part: LibraryPart, studio: [String: Data]?) async throws`, `studioFiles(libraryID:) async throws -> [String: Data]?` and `delete(libraryID:) async throws`, each followed by `reload()`. Delete of a bundled id → `PersonalLibraryError.notPersonal`, a new case.

- [ ] **Step 1: Write failing tests**
  - `studioFilesRoundTrip` (temp root).
  - `resaveWithoutStudioDropsFolder`.
  - `deleteRemovesPartAndCannotEscapeRoot`.
  - `deleteBundledIsRejected`.
  - `studioFileNamesAreValidated` (`../x.png` → error).
  - `corruptStudioFilesAreNotEditable`: garbage `draft.json` → `StudioFiles.decode` throws `PhotoPartError`. This test lives in `PhotoPartKitTests/StudioSessionTests.swift` and uses a store fixture.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(parts): personal library studio files and delete`.

### Task 7: `.fzpz` export and lossless re-import

**Files:**
- Create: `Sources/PartsKit/Zip/ZipWriter.swift`, `Sources/PartsKit/Fritzing/FzpzExporter.swift`
- Modify: `Sources/PartsKit/Fritzing/FzpzImporter.swift`
- Test: `Tests/PartsKitTests/FzpzExportTests.swift`

**Interfaces:**
- Consumes: `ZipReader`, `ZipReader.crc32`, `FzpParser`, `PartHash` (Plan 2).
- Produces:
  - `public struct ZipWriter { init(); mutating func add(_ name: String, data: Data); func finish() -> Data }`. Stored (method 0) entries only, with CRC-32 and a central directory. Output must be readable by `ZipReader`.
  - `public enum FzpzExporter { static func export(_ part: LibraryPart) throws -> Data }`. The archive layout is in Global Constraints. The `.fzp` is a `module` with `moduleId` = libraryID, title, label = labelPrefix, tags, properties (`family` included), and `connectors/connector` elements with id, name, `type` = kind and description. Each connector has `views/breadboardView/p layer="breadboard" svgId="connector<N>pin"`. The `.fzp` also has `buses`. The `.svg` has `width/height` in `mm`, a viewBox in mm, an `<image>` covering the full size with `href="data:image/png;base64,…"`, and one `rect` per connector. SVG parts export without the PNG sidecar but still get `flyingsketch.json`. All XML text is escaped.
  - `FzpzImporter.importPart`: when `flyingsketch.json` is present, decode the `PartDefinition` and take the graphic from `flyingsketch.png` (png) or the breadboard SVG (svg). Then recompute `versionHash` and `graphicAsset` as in `FzpParser`, and run `validate()`. A decode or validation failure → `PartImportError.invalidFzp("flyingsketch sidecar: …")`, with no fallback. The size guards are the same as the existing ones.

- [ ] **Step 1: Write failing tests**
  - `zipWriterRoundTripsThroughReader`.
  - `exportImportIsLossless`: a photo-part definition with roles, buses and description → imported definition == original (same versionHash).
  - `exportIsFritzingShaped`: remove the sidecar entries and import through the fzp path → the same connector ids, names and positions (±0.01 mm), and size ±0.01 mm.
  - `tamperedSidecarIsRejected`: connector at 1e9 → `.invalidFzp`.
  - `xmlSpecialCharsEscaped`: title `A&B <x>`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(parts): fzpz export with lossless FlyingSketch round-trip`.

### Task 8: StudioCanvasView — image, mask overlay, brush and trace

**Files:**
- Modify: `Package.swift` (CanvasUI → PhotoPartKit)
- Create: `Sources/CanvasUI/Studio/StudioCanvasView.swift`, `Sources/CanvasUI/Studio/StudioInputController.swift`
- Test: `Tests/CanvasUITests/StudioCanvasTests.swift`

**Interfaces:**
- Consumes: Task 5 `StudioSession`.
- Produces:
  - `public enum StudioCanvasMode: Equatable { case view, brush, trace, chooseInstance, crop, calibrate, pins }`.
  - `public final class StudioCanvasView: UIView`:
    - `init(session: StudioSession)`;
    - `var mode: StudioCanvasMode`;
    - `func refresh()`, which re-reads the session;
    - `var viewToSource: CGAffineTransform`.
  - Display:
    - in `brush`, `trace` and `chooseInstance` modes, show the source photo with the mask overlay (outside the mask dimmed 60% black; instance candidates tinted in distinct hues);
    - in the later modes, show the output preview (`toOutput` transform);
    - fit to bounds on first layout.
  - Input:
    - any single touch, Pencil or finger, drives the mode's tool;
    - two fingers pan and pinch (zoom 0.25…16× of fit) and cancel any single-touch tool action in progress;
    - `brush` collects source points and calls `session.applyBrush` on touch end;
    - `trace` collects a lasso and calls `applyTrace` on end, closing it implicitly;
    - `chooseInstance`: a tap calls `chooseInstance(at:)`.
  - `final class StudioInputController`. It holds the testable mapping and stroke-collection logic: `begin(viewPoint)`, `move`, `end() -> [Vec2] /*source*/` and `cancel()`. Points closer than 1 view pt are dropped.

- [ ] **Step 1: Write failing tests**
  - `viewToSourceAtFitAndZoom`.
  - `brushStrokeEditsMaskInSourceSpace`: a drag across the view's middle clears the expected source pixels when `brushAdds == false`.
  - `traceReplacesMask`.
  - `secondFingerCancelsStroke`: no mask change.
  - `tapChoosesInstance`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(canvas): studio canvas with mask brush and trace`.

### Task 9: StudioCanvasView — crop, calibration and pin overlays

**Files:**
- Modify: `Sources/CanvasUI/Studio/StudioCanvasView.swift`
- Create: `Sources/CanvasUI/Studio/StudioOverlays.swift`
- Test: `Tests/CanvasUITests/StudioCanvasTests.swift`

**Interfaces:**
- Consumes: Tasks 3, 8.
- Produces:
  - **`crop`:** shows the source photo with a rotated crop rectangle and 4 corner handles (44 pt hit). Dragging a corner resizes symmetrically about the centre, with a minimum of 16 px. Dragging inside moves the centre. Angle and quarter turns come from the session (set by app controls). Every change writes `session.draft.crop`.
  - **`calibrate`:** shows the output preview. The first tap sets A, the second sets B, and later taps move the nearer one. Dragging a marker moves it. Both points are written as `.twoPoints(toSource(a), toSource(b), mm: current or 2.54)`.
  - **`pins`:** shows the output preview.
    - Pin markers are drawn at r 1 mm (min 10 pt), coloured by role, with the name label beside them.
    - Tapping empty space calls `draft.addPin(atOutput:)`.
    - Tapping a pin calls `onPinSelected(id)`.
    - Dragging a pin calls `movePin`.
    - Pins outside the output bounds are drawn red.
  - `public var onPinSelected: ((String) -> Void)?` and `public var selectedPinID: String?`, the latter highlighted.

- [ ] **Step 1: Write failing tests**
  - `cropCornerDragResizes`.
  - `calibrationTapsSetTwoPoints`.
  - `tapAddsPinWithGridSnap`.
  - `dragMovesPin`.
  - `tapOnPinSelectsInsteadOfAdding`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(canvas): studio crop, calibration and pin overlays`.

### Task 10: App — PhotoPartStudio screens

**Files:**
- Create: `App/Studio/PhotoPartStudioView.swift`, `App/Studio/StudioCanvasRepresentable.swift`, `App/Studio/StudioStepControls.swift`, `App/Studio/PinEditorView.swift`, `App/Studio/BusEditorView.swift`, `App/Studio/PartDetailsForm.swift`
- Modify: `project.yml` (app depends on `PhotoPartKit`)
- Verify: app build + simulator screenshot

**Interfaces:**
- Consumes: Tasks 5, 8, 9; `PartsLibrary.save(_:studio:)` (Task 6).
- Produces:
  - `struct PhotoPartStudioView: View`:
    - `init(session: StudioSession, onSave: (LibraryPart) -> Void)`, presented full screen.
    - Top: a step bar (Cutout · Refine · Crop · Scale · Pins · Details) plus Back/Next buttons. Steps can be revisited freely.
    - Toolbar: Cancel, which confirms "Discard photo part?" when anything changed. The confirm is a SwiftUI `confirmationDialog`, not an alert.
  - **Cutout:** auto-runs on appear and shows a spinner. A status line shows `choosing` ("Tap the part to keep" + "Keep all") or `failed` ("Automatic cutout unavailable — trace the outline or use the whole photo"). Buttons: "Trace outline" (mode `trace`), "Whole photo", "Retry auto".
  - **Refine:** Add/Erase segmented control, brush size slider (2…200), undo/redo buttons bound to the session.
  - **Crop:** straighten slider −45…45° and rotate ↺/↻ (quarter turns).
  - **Scale:** picker "Two points" or "Overall width". The two-point mode has a distance field in mm (default 2.54). The width mode has a width field in mm. Shows the resulting part size "W × H mm".
  - **Pins:** a grid-snap toggle and a pin list. A selected pin opens a `PinEditorView` popover (name, kind picker male/female/pad, role picker none + all `PinRole`, description, Delete). A "Buses…" sheet (`BusEditorView`) creates a bus from multi-selected pins and deletes buses. Pins with errors are flagged.
  - **Details:** `PartDetailsForm` with title, family, label prefix, tags (comma separated) and properties (key/value rows).
  - **Save:** enabled only when `session.blockingError == nil`; otherwise shows the error text. On save: `session.build()`, then `library.save(part, studio: session.studioFiles().encoded())`, then `onSave(part)`.
  - Simulator launch argument `-photoStudioDemo` opens the studio with a generated 1200×800 image: a green board, 2 rows of gold pads at 2.54 mm-ish spacing, on grey.

- [ ] **Step 1:** Implement the screens.
- [ ] **Step 2:** Run the app build command. Expected: succeeds.
- [ ] **Step 3:** Launch on the simulator with `-photoStudioDemo` and take a screenshot of each step (`xcrun simctl io booted screenshot`). Expected: each step renders; with Vision failing on the simulator, the fallback message shows.
- [ ] **Step 4:** Commit `feat(app): photo part studio screens`.

### Task 11: App — library integration, camera, edit, export, delete

**Files:**
- Create: `App/Studio/CameraPicker.swift`, `App/Studio/PhotoPartLauncher.swift`
- Modify: `App/Views/PartsLibraryView.swift`, `App/Views/SketchEditorView.swift`, `project.yml` (camera usage key)
- Verify: app build, simulator, then device

**Interfaces:**
- Consumes: Tasks 6, 7, 10.
- Produces:
  - `PartsLibraryView` toolbar gains a "New Photo Part" menu (SF Symbol `camera.viewfinder`) with "Take Photo…" and "Choose Photo…".
    - Take Photo uses `CameraPicker`, a `UIImagePickerController` with `.camera` source, hidden when `isSourceTypeAvailable(.camera)` is false.
    - Choose Photo uses `PhotosPicker`.
    - The picked data goes through `SourceImage.load`. A failure shows "Could not read photo".
    - The studio is presented with `StudioSession(source:cutout: VisionCutout())`.
    - Saving places the part on the canvas through the existing `place` closure, then dismisses both.
  - Context menu on personal parts:
    - "Edit Photo Part…", only when `isEditable`. It loads studio files, decodes via `StudioFiles.decode`, and opens the studio with the existing draft, so `libraryID` is kept. A decode failure shows "This part can't be edited".
    - "Export .fzpz…", via `fileExporter` with `FzpzExporter.export` and file name `<title>.fzpz`.
    - "Delete", with a `confirmationDialog`, then `library.delete`.
  - After any save or delete: bump the library `generation` and call `libraryChanged()`, so the "Updates (n)" badge refreshes for documents using an edited part.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Run the package tests and the app build. Expected: all pass, build succeeds.
- [ ] **Step 3:** Install on Lars' iPad (`xcodebuild … -destination 'id=00008027-001878813EE9802E' -allowProvisioningUpdates build`, then `xcrun devicectl device install app …`).

  **Manual check (Lars):**
  1. Photograph a board with no Fritzing model (top-down).
  2. Confirm the auto cutout works, then refine an edge with the Pencil.
  3. Straighten, then calibrate on the header pitch (2.54 mm).
  4. Place header pins with grid snap, name them, and set GND/3V3 roles plus a GND bus.
  5. Save, and check the part appears on the canvas at the right size next to an ESP32 and plugs into the breadboard.
  6. Wire it, then tap a pin and check its net.
  7. Re-edit the part (move one pin); the document shows "Updates (1)"; apply it.
  8. Export `.fzpz`, delete the part, re-import it, and check the part is identical.
- [ ] **Step 4:** Commit `feat(app): photo parts in library — new, edit, export, delete`.
