import Foundation
import Testing
@testable import PhotoPartKit
import SketchCore

@Suite struct DraftGeometryTests {
    private func close(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-9) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
    }

    @Test func identityCropMapsPointsUnchanged() {
        let d = PhotoPartDraft(sourceSize: PixelSize(width: 200, height: 100))
        let p = Vec2(x: 33, y: 71)
        #expect(close(d.toOutput(p), p))
        #expect(close(d.toSource(p), p))
        #expect(d.outputSize() == Vec2(x: 200, y: 100))
    }

    @Test func quarterTurnSwapsOutputSize() {
        var d = PhotoPartDraft(sourceSize: PixelSize(width: 200, height: 100))
        d.crop.quarterTurns = 1
        #expect(d.outputSize() == Vec2(x: 100, y: 200))
        #expect(close(d.toOutput(.zero), Vec2(x: 100, y: 0)))
    }

    @Test func pinsFollowCropAndRotation() {
        var d = PhotoPartDraft(sourceSize: PixelSize(width: 400, height: 300))
        let id = d.addPin(atOutput: Vec2(x: 120, y: 80))
        let src = d.pins.first { $0.id == id }!.position
        d.crop.center = Vec2(x: 210, y: 140)
        d.crop.size = Vec2(x: 200, y: 120)
        d.crop.angle = 0.3
        d.crop.quarterTurns = 3
        #expect(close(d.toSource(d.toOutput(src)), src))
        let out = d.toOutput(src)
        #expect(close(d.toOutput(d.toSource(out)), out))
        #expect(close(d.toOutput(d.crop.center), d.outputSize() / 2))
    }

    @Test func twoPointCalibration() throws {
        var d = PhotoPartDraft(sourceSize: PixelSize(width: 400, height: 300))
        d.scale = .twoPoints(Vec2(x: 0, y: 0), Vec2(x: 254, y: 0), mm: 25.4)
        #expect(abs(try d.mmPerPixel() - 0.1) < 1e-12)
        d.scale = .twoPoints(Vec2(x: 0, y: 0), Vec2(x: 5, y: 0), mm: 25.4)
        #expect(throws: PhotoPartError.calibrationTooShort) { try d.mmPerPixel() }
        d.scale = .twoPoints(Vec2(x: 0, y: 0), Vec2(x: 254, y: 0), mm: 0)
        #expect(throws: PhotoPartError.invalidDistance) { try d.mmPerPixel() }
        d.scale = .width(mm: 40)
        #expect(abs(try d.mmPerPixel() - 0.1) < 1e-12)
        d.scale = .width(mm: .nan)
        #expect(throws: PhotoPartError.invalidDistance) { try d.mmPerPixel() }
        d.scale = nil
        #expect(throws: PhotoPartError.missingScale) { try d.mmPerPixel() }
    }

    @Test func gridSnapAnchoredAtFirstPin() {
        var d = PhotoPartDraft(sourceSize: PixelSize(width: 400, height: 300))
        d.scale = .twoPoints(Vec2(x: 0, y: 0), Vec2(x: 254, y: 0), mm: 25.4)
        let a = d.addPin(atOutput: Vec2(x: 10, y: 10))
        let b = d.addPin(atOutput: Vec2(x: 36, y: 11))
        #expect(close(d.pins.first { $0.id == a }!.position, Vec2(x: 10, y: 10)))
        #expect(close(d.pins.first { $0.id == b }!.position, Vec2(x: 35.4, y: 10)))
        #expect(d.pins.map(\.name) == ["P1", "P2"])
        d.movePin(b, toOutput: Vec2(x: 62, y: 9))
        #expect(close(d.pins[1].position, Vec2(x: 60.8, y: 10)))
        d.movePin(a, toOutput: Vec2(x: 12.3, y: 14.7))
        #expect(close(d.pins[0].position, Vec2(x: 12.3, y: 14.7)))
    }

    @Test func noSnapWithoutScaleOrWhenDisabled() {
        var d = PhotoPartDraft(sourceSize: PixelSize(width: 400, height: 300))
        _ = d.addPin(atOutput: Vec2(x: 10, y: 10))
        let b = d.addPin(atOutput: Vec2(x: 36, y: 11))
        #expect(close(d.pins.first { $0.id == b }!.position, Vec2(x: 36, y: 11)))
        d.scale = .width(mm: 40)
        d.gridSnap = false
        let c = d.addPin(atOutput: Vec2(x: 37, y: 12))
        #expect(close(d.pins.first { $0.id == c }!.position, Vec2(x: 37, y: 12)))
    }

    @Test func removePinCleansBuses() {
        var d = PhotoPartDraft(sourceSize: PixelSize(width: 400, height: 300))
        let a = d.addPin(atOutput: Vec2(x: 1, y: 1))
        let b = d.addPin(atOutput: Vec2(x: 2, y: 2))
        let c = d.addPin(atOutput: Vec2(x: 3, y: 3))
        d.buses = [[a, b, c], [a, b]]
        d.removePin(c)
        #expect(d.buses == [[a, b], [a, b]])
        d.removePin(b)
        #expect(d.buses.isEmpty)
        let n = d.addPin(atOutput: Vec2(x: 5, y: 5))
        #expect(n != c && n != b)
        #expect(d.pins.last?.name == "P4")
    }

    @Test func draftCodableRoundTrip() throws {
        var d = PhotoPartDraft(sourceSize: PixelSize(width: 400, height: 300))
        d.scale = .width(mm: 30)
        _ = d.addPin(atOutput: Vec2(x: 10, y: 10))
        d.metadata.title = "T"
        let back = try JSONDecoder().decode(PhotoPartDraft.self, from: JSONEncoder().encode(d))
        #expect(back == d)
        #expect(d.libraryID.hasPrefix("photo-"))
        #expect(d.metadata.family == "Photo parts" && d.metadata.labelPrefix == "U")
    }
}
