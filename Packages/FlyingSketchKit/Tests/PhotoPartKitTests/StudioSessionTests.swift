import Foundation
import SketchCore
import Testing
@testable import PhotoPartKit

private struct FakeCutout: CutoutProviding {
    var result: Result<[MaskBitmap], PhotoPartError>
    func instances(in image: SourceImage) async throws(PhotoPartError) -> [MaskBitmap] {
        try result.get()
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
}
