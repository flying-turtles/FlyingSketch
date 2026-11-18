import Foundation
import SketchCore
import Testing
import PartsKit
@testable import PhotoPartKit

private struct FakeCutout: CutoutProviding {
    var result: Result<[MaskBitmap], PhotoPartError>
    func instances(in image: SourceImage) async throws(PhotoPartError) -> [MaskBitmap] {
        try result.get()
    }
}

private final class Gate: @unchecked Sendable {
    private var cont: CheckedContinuation<Void, Never>?
    private var open = false
    func wait() async {
        await withCheckedContinuation { c in
            if open { c.resume() } else { cont = c }
        }
    }
    func release() { open = true; cont?.resume(); cont = nil }
}

private struct SlowCutout: CutoutProviding {
    let gate: Gate
    let result: [MaskBitmap]
    func instances(in image: SourceImage) async throws(PhotoPartError) -> [MaskBitmap] {
        await gate.wait()
        return result
    }
}

@MainActor @Suite struct StudioSessionTests {
    static let w = 100, h = 50

    static func source() -> SourceImage {
        SourceImage(image: PhotoFixtures.rgbImage(width: w, height: h) { _, _ in (10, 20, 30) })
    }

    static func block(x0: Int, x1: Int) -> MaskBitmap {
        var m = MaskBitmap(width: w, height: h, filled: false)
        for y in 0..<h { for x in x0..<x1 { m.bytes[y * w + x] = 255 } }
        return m
    }

    static func session(_ r: Result<[MaskBitmap], PhotoPartError>) -> StudioSession {
        StudioSession(source: source(), cutout: FakeCutout(result: r))
    }

    @Test func singleInstanceAppliesDirectly() async {
        let m = Self.block(x0: 0, x1: 20)
        let s = Self.session(.success([m]))
        await s.runAutoCutout()
        #expect(s.cutoutState == .done)
        #expect(s.mask == m)
        #expect(s.canUndoMask)
    }

    @Test func autoCutoutCropsToMaskBoundsPlusMargin() async {
        // Mask x 30..59, y 10..39 (30x30): margin max(4, 0.6) = 4 -> x 26...64, y 6...44.
        var m = MaskBitmap(width: Self.w, height: Self.h, filled: false)
        for y in 10..<40 { for x in 30..<60 { m.bytes[y * Self.w + x] = 255 } }
        let s = Self.session(.success([m]))
        await s.runAutoCutout()
        #expect(s.draft.crop == CropSpec(center: Vec2(x: 45, y: 25), size: Vec2(x: 38, y: 38)))
        // Clamped to the source edges.
        let edge = Self.session(.success([Self.block(x0: 0, x1: 20)]))
        await edge.runAutoCutout()
        #expect(edge.draft.crop == CropSpec(center: Vec2(x: 12, y: 25), size: Vec2(x: 24, y: 50)))
    }

    @Test func autoCropSkippedWhenUserChangedCrop() async {
        let s = Self.session(.success([Self.block(x0: 30, x1: 60)]))
        let custom = CropSpec(center: Vec2(x: 50, y: 25), size: Vec2(x: 80, y: 40), quarterTurns: 1)
        s.draft.crop = custom
        await s.runAutoCutout()
        #expect(s.draft.crop == custom)
    }

    @Test func brushAndWholePhotoLeaveCropAlone() {
        let s = Self.session(.success([]))
        let full = CropSpec.full(PixelSize(width: Self.w, height: Self.h))
        s.brushAdds = false
        s.brushRadius = 10
        s.applyBrush([Vec2(x: 10, y: 10)])
        #expect(s.canUndoMask)
        #expect(s.draft.crop == full)
        s.useWholePhoto()
        #expect(s.draft.crop == full)
    }

    @Test func chooseAndTraceAutoCrop() async throws {
        let a = Self.block(x0: 0, x1: 20), b = Self.block(x0: 60, x1: 80)
        let s = Self.session(.success([a, b]))
        await s.runAutoCutout()
        #expect(s.draft.crop == .full(PixelSize(width: Self.w, height: Self.h)))
        s.chooseAllInstances()
        #expect(s.draft.crop == CropSpec(center: Vec2(x: 42, y: 25), size: Vec2(x: 84, y: 50)))
        let t = Self.session(.failure(.cutoutUnavailable))
        await t.runAutoCutout()
        try t.applyTrace([Vec2(x: 0, y: 0), Vec2(x: 40, y: 0), Vec2(x: 40, y: 40), Vec2(x: 0, y: 40)])
        #expect(t.draft.crop != .full(PixelSize(width: Self.w, height: Self.h)))
        #expect(t.draft.crop.angle == 0)
    }

    @Test func multipleInstancesAskToChoose() async {
        let a = Self.block(x0: 0, x1: 20), b = Self.block(x0: 60, x1: 80)
        let s = Self.session(.success([a, b]))
        await s.runAutoCutout()
        #expect(s.cutoutState == .choosing(count: 2))
        #expect(s.mask.bytes.allSatisfy { $0 == 255 })
        s.chooseInstance(at: Vec2(x: 5, y: 5))
        #expect(s.cutoutState == .done)
        #expect(s.mask == a)
    }

    @Test func chooseAllUnions() async {
        let a = Self.block(x0: 0, x1: 20), b = Self.block(x0: 60, x1: 80)
        let s = Self.session(.success([a, b]))
        await s.runAutoCutout()
        s.chooseAllInstances()
        #expect(s.mask.value(at: Vec2(x: 5, y: 5)) && s.mask.value(at: Vec2(x: 65, y: 5)))
        #expect(!s.mask.value(at: Vec2(x: 40, y: 5)))
    }

    @Test func cutoutFailureFallsBackToManual() async throws {
        let s = Self.session(.failure(.cutoutUnavailable))
        await s.runAutoCutout()
        #expect(s.cutoutState == .failed(.cutoutUnavailable))
        #expect(s.mask.bytes.allSatisfy { $0 == 255 })
        try s.applyTrace([Vec2(x: 0, y: 0), Vec2(x: 40, y: 0), Vec2(x: 40, y: 40), Vec2(x: 0, y: 40)])
        #expect(s.mask.value(at: Vec2(x: 20, y: 20)))
        #expect(!s.mask.value(at: Vec2(x: 80, y: 20)))
        #expect(throws: PhotoPartError.traceTooShort) { try s.applyTrace([Vec2(x: 0, y: 0)]) }
    }

    @Test func brushUndoRedoDepth20() {
        let s = Self.session(.success([]))
        s.brushAdds = false
        s.brushRadius = 2
        for i in 0..<25 { s.applyBrush([Vec2(x: 2 + Double(i) * 3.5, y: 25)]) }
        var undone = 0
        while s.canUndoMask { s.undoMask(); undone += 1 }
        #expect(undone == 20)
        s.redoMask()
        #expect(s.canRedoMask)
        s.applyBrush([Vec2(x: 90, y: 5)])
        #expect(!s.canRedoMask)
    }

    @Test func noOpBrushPushesNothing() {
        let s = Self.session(.success([]))
        s.applyBrush([])
        s.applyBrush([Vec2(x: 10, y: 10)])  // add on full mask
        #expect(!s.canUndoMask)
    }

    @Test func brushRadiusClamped() {
        let s = Self.session(.success([]))
        s.brushRadius = 1000
        #expect(s.brushRadius == 200)
        s.brushRadius = 0
        #expect(s.brushRadius == 2)
    }

    @Test func blockingErrorTracksDraft() {
        let s = Self.session(.success([]))
        #expect(s.blockingError == .emptyTitle)
        s.draft.metadata.title = "Part"
        s.draft.scale = .width(mm: 10)
        #expect(s.blockingError == nil)
        s.brushAdds = false
        s.brushRadius = 200
        s.applyBrush([Vec2(x: 50, y: 25)])
        #expect(s.mask.boundingBox == nil)
        #expect(s.blockingError == .emptyMask)
    }

    @Test func studioFilesRoundTrip() throws {
        let s = Self.session(.success([]))
        s.draft.metadata.title = "Part"
        s.useWholePhoto()
        let files = try s.studioFiles().encoded()
        #expect(Set(files.keys) == ["draft.json", "source.png", "mask.png"])
        let (src, mask, draft) = try StudioFiles.decode(files)
        #expect(src.pixelSize == s.source.pixelSize)
        #expect(mask == s.mask)
        #expect(draft == s.draft)
    }

    @Test func emptyResultFails() async {
        let s = Self.session(.success([]))
        await s.runAutoCutout()
        #expect(s.cutoutState == .failed(.noForeground))
        #expect(s.instances.isEmpty)
    }

    @Test func failureClearsInstances() async {
        let s = Self.session(.success([Self.block(x0: 0, x1: 10), Self.block(x0: 50, x1: 60)]))
        await s.runAutoCutout()
        #expect(s.instances.count == 2)
        let s2 = StudioSession(source: Self.source(), cutout: FakeCutout(result: .failure(.cutoutUnavailable)))
        await s2.runAutoCutout()
        #expect(s2.instances.isEmpty)
    }

    @Test func wrongSizeMaskIgnored() {
        let bad = MaskBitmap(width: 3, height: 3, filled: false)
        let s = StudioSession(source: Self.source(), cutout: FakeCutout(result: .success([])), mask: bad)
        #expect(s.mask.width == Self.w && s.mask.height == Self.h)
        #expect(s.mask.bytes.allSatisfy { $0 == 255 })
    }

    @Test func staleRunIsDiscarded() async {
        let gate = Gate()
        let s = StudioSession(source: Self.source(),
                              cutout: SlowCutout(gate: gate, result: [Self.block(x0: 0, x1: 20)]))
        let run = Task { @MainActor in await s.runAutoCutout() }
        while s.cutoutState != .running { await Task.yield() }
        s.useWholePhoto()
        gate.release()
        await run.value
        #expect(s.cutoutState == .done)
        #expect(s.mask.bytes.allSatisfy { $0 == 255 })
    }

    @Test func undoRedoRestoreContents() throws {
        let s = Self.session(.success([]))
        let full = s.mask
        try s.applyTrace([Vec2(x: 0, y: 0), Vec2(x: 40, y: 0), Vec2(x: 40, y: 40), Vec2(x: 0, y: 40)])
        let traced = s.mask
        #expect(traced != full)
        s.undoMask()
        #expect(s.mask == full)
        s.redoMask()
        #expect(s.mask == traced)
    }

    @Test func storedMaskSkipsAutoCutout() async {
        let stored = Self.block(x0: 10, x1: 30)
        var draft = PhotoPartDraft(sourceSize: PixelSize(width: Self.w, height: Self.h))
        draft.metadata.title = "Saved"
        let s = StudioSession(source: Self.source(), cutout: FakeCutout(result: .success([Self.block(x0: 0, x1: 90)])),
                              draft: draft, mask: stored)
        #expect(s.cutoutState == .done)
        #expect(s.step == .pins)
        #expect(s.mask == stored && s.draft == draft && !s.canUndoMask)
        // The view's first-cutout guard only runs from `.idle`; an explicit retry still works.
        await s.runAutoCutout()
        #expect(s.mask == Self.block(x0: 0, x1: 90))
        s.undoMask()
        #expect(s.mask == stored)
    }

    @Test func maskIsEmptyTracksUndoRedo() throws {
        let s = Self.session(.success([]))
        #expect(!s.maskIsEmpty)
        s.brushAdds = false
        s.brushRadius = 200
        s.applyBrush([Vec2(x: 50, y: 25)])
        #expect(s.maskIsEmpty && s.blockingError == .emptyMask)
        s.undoMask()
        #expect(!s.maskIsEmpty && s.blockingError != .emptyMask)
        s.redoMask()
        #expect(s.maskIsEmpty)
        s.useWholePhoto()
        #expect(!s.maskIsEmpty)
        let empty = StudioSession(source: Self.source(), cutout: FakeCutout(result: .success([])),
                                  mask: MaskBitmap(width: Self.w, height: Self.h, filled: false))
        #expect(empty.maskIsEmpty && empty.blockingError == .emptyMask)
    }

    @Test func snapshotBuildsLikeSession() throws {
        let s = Self.session(.success([]))
        s.draft.metadata.title = "Part"
        s.draft.scale = .width(mm: 10)
        let snap = s.snapshot()
        #expect(try snap.build() == s.build())
        #expect(snap.studioFiles() == s.studioFiles())
    }

    @Test func chooseInstanceNoOps() async {
        let s = Self.session(.success([Self.block(x0: 0, x1: 20), Self.block(x0: 60, x1: 80)]))
        s.chooseInstance(at: Vec2(x: 5, y: 5))  // idle
        #expect(s.cutoutState == .idle && !s.canUndoMask)
        await s.runAutoCutout()
        s.chooseInstance(at: Vec2(x: 40, y: 5))  // no instance
        #expect(s.cutoutState == .choosing(count: 2) && !s.canUndoMask)
    }
}

@Suite struct StudioCorruptFilesTests {
    @Test func corruptStudioFilesAreNotEditable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudioCorrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalLibraryStore(rootURL: root)
        let def = PartDefinition(libraryID: "p", versionHash: "h", title: "P", family: "photo", size: Vec2(x: 5, y: 5),
                                 graphicAsset: "g.svg", graphicKind: .svg)
        let part = LibraryPart(definition: def, graphic: Data("<svg/>".utf8), source: .personal)
        try store.write(part, studio: ["draft.json": Data("garbage".utf8), "source.png": Data([1]), "mask.png": Data([2])])
        let files = try #require(try store.studioFiles(forLibraryID: "p"))
        #expect(throws: PhotoPartError.self) { try StudioFiles.decode(files) }
    }

    @MainActor @Test func invalidDraftsAreRejected() throws {
        let s = StudioSession(source: StudioSessionTests.source(), cutout: FakeCutout(result: .success([])))
        s.draft.metadata.title = "Part"
        s.draft.scale = .width(mm: 10)
        s.draft.addPin(atOutput: Vec2(x: 10, y: 10))
        s.draft.addPin(atOutput: Vec2(x: 30, y: 10))
        s.draft.buses = [["connector0", "connector1"]]
        let good = s.draft
        let base = try s.studioFiles().encoded()
        func files(_ d: PhotoPartDraft) throws -> [String: Data] {
            var f = base
            let enc = JSONEncoder()
            // Non-finite values can't be plain JSON; written as strings they fail decoding (still rejected).
            enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            f["draft.json"] = try enc.encode(d)
            return f
        }
        _ = try StudioFiles.decode(files(good))

        var cases: [(String, (inout PhotoPartDraft) -> Void)] = []
        cases.append(("quarterTurns", { $0.crop.quarterTurns = 4 }))
        cases.append(("negative quarterTurns", { $0.crop.quarterTurns = -1 }))
        cases.append(("angle", { $0.crop.angle = .pi / 4 + 0.01 }))
        cases.append(("angle nan", { $0.crop.angle = .nan }))
        cases.append(("center", { $0.crop.center.x = .infinity }))
        cases.append(("size zero", { $0.crop.size.y = 0 }))
        cases.append(("size nan", { $0.crop.size.x = .nan }))
        cases.append(("width scale", { $0.scale = .width(mm: .infinity) }))
        cases.append(("two-point scale", { $0.scale = .twoPoints(Vec2(x: .nan, y: 0), Vec2(x: 50, y: 0), mm: 10) }))
        cases.append(("two-point mm", { $0.scale = .twoPoints(Vec2(x: 0, y: 0), Vec2(x: 50, y: 0), mm: .nan) }))
        cases.append(("duplicate ids", { $0.pins[1].id = $0.pins[0].id }))
        cases.append(("pin position", { $0.pins[0].position.y = .infinity }))
        cases.append(("nextPinNumber reused", { $0.nextPinNumber = 1 }))
        cases.append(("nextPinNumber huge", { $0.nextPinNumber = 100_001 }))
        cases.append(("nextPinNumber negative", { $0.nextPinNumber = -1 }))
        cases.append(("bus unknown pin", { $0.buses = [["connector0", "connector9"]] }))
        for (name, mutate) in cases {
            var d = good
            mutate(&d)
            #expect(!StudioFiles.isStructurallyValid(d), "\(name)")
            #expect(throws: PhotoPartError.undecodableImage, "\(name)") { try StudioFiles.decode(files(d)) }
        }
        // Edge values still accepted.
        var edge = good
        edge.crop.angle = -.pi / 4
        edge.crop.quarterTurns = 3
        edge.nextPinNumber = 100_000
        _ = try StudioFiles.decode(files(edge))
    }

    @MainActor @Test func wrongSizeMaskIsNotEditable() throws {
        let s = StudioSession(source: StudioSessionTests.source(), cutout: FakeCutout(result: .success([])))
        var files = try s.studioFiles().encoded()
        files["mask.png"] = MaskBitmap(width: 3, height: 3, filled: true).pngData()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudioCorrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalLibraryStore(rootURL: root)
        let def = PartDefinition(libraryID: "p", versionHash: "h", title: "P", family: "photo", size: Vec2(x: 5, y: 5),
                                 graphicAsset: "g.svg", graphicKind: .svg)
        try store.write(LibraryPart(definition: def, graphic: Data("<svg/>".utf8), source: .personal), studio: files)
        let back = try #require(try store.studioFiles(forLibraryID: "p"))
        #expect(throws: PhotoPartError.self) { try StudioFiles.decode(back) }
    }
}
