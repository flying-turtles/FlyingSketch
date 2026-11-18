import CoreGraphics
import PhotoPartKit
import SketchCore
import Testing
import UIKit
@testable import CanvasUI

private struct FakeCutout: CutoutProviding {
    var masks: [MaskBitmap] = []
    func instances(in image: SourceImage) async throws(PhotoPartError) -> [MaskBitmap] { masks }
}

@MainActor @Suite struct StudioCanvasTests {
    static let w = 200, h = 100

    static func source() -> SourceImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let png = UIImage(cgImage: ctx.makeImage()!).pngData()!
        return try! SourceImage.load(png)
    }

    static func block(x0: Int, x1: Int) -> MaskBitmap {
        var m = MaskBitmap(width: w, height: h, filled: false)
        for y in 0..<h { for x in x0..<x1 { m.bytes[y * w + x] = 255 } }
        return m
    }

    /// 400×400 view: fit scale 2, image spans y 100…300.
    static func canvas(_ session: StudioSession, mode: StudioCanvasMode) -> StudioCanvasView {
        let v = StudioCanvasView(session: session)
        v.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        v.layoutIfNeeded()
        v.mode = mode
        return v
    }

    static func maskValue(_ s: StudioSession, _ x: Int, _ y: Int) -> UInt8 { s.mask.bytes[y * w + x] }

    static func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }

    @Test func viewToSourceAtFitAndZoom() {
        let v = Self.canvas(StudioSession(source: Self.source(), cutout: FakeCutout()), mode: .brush)
        #expect(Self.close(CGPoint(x: 0, y: 100).applying(v.viewToSource), CGPoint(x: 0, y: 0)))
        #expect(Self.close(CGPoint(x: 400, y: 300).applying(v.viewToSource), CGPoint(x: 200, y: 100)))

        v.zoom(by: 2, around: CGPoint(x: 200, y: 200))
        #expect(Self.close(CGPoint(x: 200, y: 200).applying(v.viewToSource), CGPoint(x: 100, y: 50)))
        #expect(Self.close(CGPoint(x: 0, y: 100).applying(v.viewToSource), CGPoint(x: 50, y: 25)))

        v.pan(by: CGPoint(x: 40, y: 0))
        #expect(Self.close(CGPoint(x: 240, y: 200).applying(v.viewToSource), CGPoint(x: 100, y: 50)))

        v.zoom(by: 1000, around: CGPoint(x: 200, y: 200))
        #expect(abs(1 / v.viewToSource.a - 2 * 16) < 1e-6) // clamped to 16× fit
        v.zoom(by: 0.0001, around: CGPoint(x: 200, y: 200))
        #expect(abs(1 / v.viewToSource.a - 2 * 0.25) < 1e-6) // clamped to 0.25× fit
    }

    @Test func brushStrokeEditsMaskInSourceSpace() {
        let s = StudioSession(source: Self.source(), cutout: FakeCutout())
        s.brushAdds = false
        s.brushRadius = 5
        let v = Self.canvas(s, mode: .brush)
        v.touchDown(at: CGPoint(x: 0, y: 200), isPencil: false, directTouchCount: 1)
        v.touchMoved(to: CGPoint(x: 200, y: 200))
        v.touchMoved(to: CGPoint(x: 400, y: 200))
        #expect(Self.maskValue(s, 100, 50) == 255) // applied on touch end only
        v.touchEnded()
        #expect(Self.maskValue(s, 100, 50) == 0)
        #expect(Self.maskValue(s, 10, 50) == 0)
        #expect(Self.maskValue(s, 190, 50) == 0)
        #expect(Self.maskValue(s, 100, 58) == 255)
        #expect(Self.maskValue(s, 100, 10) == 255)
    }

    @Test func traceReplacesMask() {
        let s = StudioSession(source: Self.source(), cutout: FakeCutout())
        let v = Self.canvas(s, mode: .trace)
        v.touchDown(at: CGPoint(x: 100, y: 150), isPencil: true, directTouchCount: 0)
        v.touchMoved(to: CGPoint(x: 300, y: 150))
        v.touchMoved(to: CGPoint(x: 300, y: 250))
        v.touchMoved(to: CGPoint(x: 100, y: 250)) // closed implicitly
        v.touchEnded()
        #expect(Self.maskValue(s, 100, 50) == 255)
        #expect(Self.maskValue(s, 55, 30) == 255)
        #expect(Self.maskValue(s, 10, 10) == 0)
        #expect(Self.maskValue(s, 160, 50) == 0)
        #expect(s.canUndoMask)
    }

    @Test func secondFingerCancelsStroke() {
        let s = StudioSession(source: Self.source(), cutout: FakeCutout())
        s.brushAdds = false
        let before = s.mask
        let v = Self.canvas(s, mode: .brush)
        v.touchDown(at: CGPoint(x: 0, y: 200), isPencil: false, directTouchCount: 1)
        v.touchMoved(to: CGPoint(x: 200, y: 200))
        v.touchDown(at: CGPoint(x: 300, y: 300), isPencil: false, directTouchCount: 2)
        v.touchMoved(to: CGPoint(x: 400, y: 200))
        v.touchEnded()
        #expect(s.mask == before)
        #expect(!s.canUndoMask)

        // A pan/pinch beginning cancels even a Pencil stroke.
        v.touchDown(at: CGPoint(x: 0, y: 200), isPencil: true, directTouchCount: 0)
        v.touchMoved(to: CGPoint(x: 200, y: 200))
        v.gestureBegan()
        v.touchEnded()
        #expect(s.mask == before)
    }

    @Test func tapChoosesInstance() async {
        let left = Self.block(x0: 0, x1: 100), right = Self.block(x0: 100, x1: 200)
        let s = StudioSession(source: Self.source(), cutout: FakeCutout(masks: [left, right]))
        await s.runAutoCutout()
        #expect(s.cutoutState == .choosing(count: 2))
        let v = Self.canvas(s, mode: .chooseInstance)
        v.refresh()
        v.touchDown(at: CGPoint(x: 300, y: 200), isPencil: false, directTouchCount: 1) // source (150, 50)
        v.touchEnded()
        #expect(s.mask == right)
        #expect(s.cutoutState == .done)
    }

    @Test func outputModesMapThroughCrop() {
        let s = StudioSession(source: Self.source(), cutout: FakeCutout())
        s.draft.crop = CropSpec(center: Vec2(x: 100, y: 50), size: Vec2(x: 100, y: 50), quarterTurns: 1)
        let v = Self.canvas(s, mode: .calibrate)
        v.refresh()
        // Output 50×100 fits 400×400 at scale 4, centered: x 100…300.
        let center = CGPoint(x: 200, y: 200).applying(v.viewToSource)
        #expect(Self.close(center, CGPoint(x: 100, y: 50)))
        let corner = CGPoint(x: 100, y: 0).applying(v.viewToSource)
        let expected = s.draft.toSource(Vec2(x: 0, y: 0))
        #expect(Self.close(corner, CGPoint(x: expected.x, y: expected.y)))
    }

    static func closeV(_ a: Vec2, _ b: Vec2) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }

    static func tap(_ v: StudioCanvasView, _ p: CGPoint) {
        v.touchDown(at: p, isPencil: false, directTouchCount: 1)
        v.touchEnded()
    }

    static func drag(_ v: StudioCanvasView, _ pts: [CGPoint]) {
        v.touchDown(at: pts[0], isPencil: false, directTouchCount: 1)
        for p in pts.dropFirst() { v.touchMoved(to: p) }
        v.touchEnded()
    }

    static func view(_ v: StudioCanvasView, source p: Vec2) -> CGPoint {
        CGPoint(x: p.x, y: p.y).applying(v.viewToSource.inverted())
    }

    @Test func layersAgreeWithViewToSource() {
        let s = StudioSession(source: Self.source(), cutout: FakeCutout())
        s.draft.crop = CropSpec(center: Vec2(x: 90, y: 55), size: Vec2(x: 120, y: 60), angle: 0.2, quarterTurns: 1)
        let p = CGPoint(x: 30, y: 70)
        for mode in [StudioCanvasMode.brush, .calibrate] {
            let v = Self.canvas(s, mode: mode)
            v.zoom(by: 1.7, around: CGPoint(x: 120, y: 260))
            v.pan(by: CGPoint(x: -15, y: 22))
            let viaLayers = v.layer.convert(p, from: v.imageLayer)
            #expect(Self.close(viaLayers, p.applying(v.viewToSource.inverted())), "\(mode)")
        }
    }

    @Test func cropModeShowsSourceAndFitsOnSwitch() {
        let s = StudioSession(source: Self.source(), cutout: FakeCutout())
        s.draft.crop = CropSpec(center: Vec2(x: 100, y: 50), size: Vec2(x: 100, y: 50), quarterTurns: 1)
        let v = Self.canvas(s, mode: .crop)
        #expect(Self.close(CGPoint(x: 0, y: 100).applying(v.viewToSource), .zero)) // source fit
        v.zoom(by: 3, around: .zero)
        v.mode = .calibrate // source → output: refit
        #expect(Self.close(CGPoint(x: 200, y: 200).applying(v.viewToSource), CGPoint(x: 100, y: 50)))
        #expect(abs(hypot(v.viewToSource.a, v.viewToSource.b) - 0.25) < 1e-6) // output 50×100 fit scale 4
    }

    @Test func cropCornerDragResizes() {
        let s = StudioSession(source: Self.source(), cutout: FakeCutout())
        let v = Self.canvas(s, mode: .crop)
        // Full crop: bottom-right corner at source (200, 100) = view (400, 300).
        Self.drag(v, [CGPoint(x: 400, y: 300), CGPoint(x: 360, y: 280)])
        #expect(Self.closeV(s.draft.crop.size, Vec2(x: 160, y: 80)))
        #expect(Self.closeV(s.draft.crop.center, Vec2(x: 100, y: 50)))

        // Inside drag moves the centre.
        Self.drag(v, [CGPoint(x: 200, y: 200), CGPoint(x: 220, y: 190)])
        #expect(Self.closeV(s.draft.crop.center, Vec2(x: 110, y: 45)))
        #expect(Self.closeV(s.draft.crop.size, Vec2(x: 160, y: 80)))

        // Minimum 16 px each side.
        let corner = Self.view(v, source: Vec2(x: 190, y: 85))
        Self.drag(v, [corner, Self.view(v, source: Vec2(x: 111, y: 45))])
        #expect(Self.closeV(s.draft.crop.size, Vec2(x: 16, y: 16)))

        // Rotated crop: resize is symmetric in the crop's own frame.
        let a = Double.pi / 6, c = Vec2(x: 100, y: 50)
        s.draft.crop = CropSpec(center: c, size: Vec2(x: 100, y: 50), angle: a)
        v.refresh()
        Self.drag(v, [Self.view(v, source: c + Vec2(x: -50, y: 25).rotated(by: a)),
                      Self.view(v, source: c + Vec2(x: -60, y: 30).rotated(by: a))])
        #expect(abs(s.draft.crop.size.x - 120) < 1e-6 && abs(s.draft.crop.size.y - 60) < 1e-6)
        #expect(Self.closeV(s.draft.crop.center, c))
        #expect(s.draft.crop.angle == a)
    }

    @Test func calibrationTapsSetTwoPoints() {
        let s = StudioSession(source: Self.source(), cutout: FakeCutout())
        s.draft.scale = .width(mm: 10)
        let v = Self.canvas(s, mode: .calibrate) // full crop: output == source, fit 2
        Self.tap(v, CGPoint(x: 100, y: 200)) // A = (50, 50), pending in view
        #expect(s.draft.scale == .width(mm: 10))
        Self.tap(v, CGPoint(x: 300, y: 200)) // B = (150, 50)
        #expect(s.draft.scale == .twoPoints(Vec2(x: 50, y: 50), Vec2(x: 150, y: 50), mm: 2.54))
        Self.tap(v, CGPoint(x: 280, y: 220)) // nearer B moves
        #expect(s.draft.scale == .twoPoints(Vec2(x: 50, y: 50), Vec2(x: 140, y: 60), mm: 2.54))

        s.draft.scale = .twoPoints(Vec2(x: 50, y: 50), Vec2(x: 140, y: 60), mm: 5)
        Self.drag(v, [CGPoint(x: 103, y: 198), CGPoint(x: 115, y: 200), CGPoint(x: 120, y: 200)]) // drag A marker
        #expect(s.draft.scale == .twoPoints(Vec2(x: 60, y: 50), Vec2(x: 140, y: 60), mm: 5))
    }

    @Test func tapAddsPinWithGridSnap() {
        let s = StudioSession(source: Self.source(), cutout: FakeCutout())
        s.draft.scale = .twoPoints(Vec2(x: 0, y: 0), Vec2(x: 100, y: 0), mm: 25.4) // pitch 10 px = 20 pt
        let v = Self.canvas(s, mode: .pins)
        Self.tap(v, CGPoint(x: 100, y: 200)) // output (50, 50)
        Self.tap(v, CGPoint(x: 143, y: 212)) // output (71.5, 56) → snapped (70, 60)
        #expect(s.draft.pins.count == 2)
        #expect(Self.closeV(s.draft.pins[0].position, Vec2(x: 50, y: 50)))
        #expect(Self.closeV(s.draft.pins[1].position, Vec2(x: 70, y: 60)))
    }

    @Test func dragMovesPin() {
        let s = StudioSession(source: Self.source(), cutout: FakeCutout())
        s.draft.gridSnap = false
        let id = s.draft.addPin(atOutput: Vec2(x: 50, y: 50))
        let v = Self.canvas(s, mode: .pins)
        var selected: [String] = []
        v.onPinSelected = { selected.append($0) }
        Self.drag(v, [CGPoint(x: 100, y: 200), CGPoint(x: 140, y: 200), CGPoint(x: 160, y: 240)])
        #expect(s.draft.pins.count == 1)
        #expect(s.draft.pins[0].id == id)
        #expect(Self.closeV(s.draft.pins[0].position, Vec2(x: 80, y: 70)))
        #expect(selected.isEmpty)

        // A second finger cancels the drag and restores the pin.
        v.touchDown(at: CGPoint(x: 160, y: 240), isPencil: false, directTouchCount: 1)
        v.touchMoved(to: CGPoint(x: 220, y: 240))
        v.touchDown(at: CGPoint(x: 10, y: 10), isPencil: false, directTouchCount: 2)
        v.touchEnded()
        #expect(Self.closeV(s.draft.pins[0].position, Vec2(x: 80, y: 70)))
    }

    @Test func tapOnPinSelectsInsteadOfAdding() {
        let s = StudioSession(source: Self.source(), cutout: FakeCutout())
        let id = s.draft.addPin(atOutput: Vec2(x: 50, y: 50))
        let v = Self.canvas(s, mode: .pins)
        var selected: [String] = []
        v.onPinSelected = { selected.append($0) }
        Self.tap(v, CGPoint(x: 112, y: 207)) // within 22 pt hit radius of view (100, 200)
        #expect(selected == [id])
        #expect(s.draft.pins.count == 1)
        v.touchDown(at: CGPoint(x: 100, y: 200), isPencil: false, directTouchCount: 1)
        v.touchMoved(to: CGPoint(x: 102, y: 202)) // under 4 pt: still a tap
        v.touchEnded()
        #expect(selected == [id, id])
        #expect(Self.closeV(s.draft.pins[0].position, Vec2(x: 50, y: 50)))
        Self.tap(v, CGPoint(x: 300, y: 200)) // empty space adds
        #expect(s.draft.pins.count == 2)
        #expect(selected == [id, id])
    }

    @Test func inputControllerDropsClosePointsAndMaps() {
        let c = StudioInputController()
        c.viewToSource = CGAffineTransform(scaleX: 0.5, y: 0.5)
        c.begin(CGPoint(x: 10, y: 10))
        c.move(CGPoint(x: 10.5, y: 10.5)) // < 1 pt: dropped
        c.move(CGPoint(x: 12, y: 10))
        #expect(c.viewPoints.count == 2)
        let pts = c.end()
        #expect(pts == [Vec2(x: 5, y: 5), Vec2(x: 6, y: 5)])
        #expect(!c.isActive)
        #expect(c.end().isEmpty)

        c.begin(CGPoint(x: 0, y: 0))
        c.move(CGPoint(x: 5, y: 5))
        c.cancel()
        #expect(!c.isActive)
        #expect(c.end().isEmpty)
    }
}
