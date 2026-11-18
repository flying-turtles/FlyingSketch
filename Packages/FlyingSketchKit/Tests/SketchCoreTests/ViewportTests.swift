import Foundation
import Testing
@testable import SketchCore

@Test func roundTripsWorldViewWorld() {
    let vp = Viewport(center: Vec2(x: 10, y: -5), zoom: 2.5)
    let size = Vec2(x: 1024, y: 768)
    let p = Vec2(x: 3.3, y: 7.7)
    let back = vp.viewToWorld(vp.worldToView(p, viewSize: size), viewSize: size)
    #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
}

@Test func centerMapsToViewCenter() {
    let vp = Viewport(center: Vec2(x: 10, y: 20), zoom: 1)
    #expect(vp.worldToView(Vec2(x: 10, y: 20), viewSize: Vec2(x: 800, y: 600)) == Vec2(x: 400, y: 300))
}

@Test func oneMillimetreAtZoomOne() {
    let vp = Viewport(center: .zero, zoom: 1)
    let a = vp.worldToView(.zero, viewSize: Vec2(x: 100, y: 100))
    let b = vp.worldToView(Vec2(x: 1, y: 0), viewSize: Vec2(x: 100, y: 100))
    #expect(abs((b.x - a.x) - 160.0 / 25.4) < 1e-9)
}

@Test func zoomKeepsAnchorFixed() {
    var vp = Viewport(center: .zero, zoom: 1)
    let size = Vec2(x: 800, y: 600), anchor = Vec2(x: 100, y: 50)
    let before = vp.viewToWorld(anchor, viewSize: size)
    vp.zoom(by: 3, around: anchor, viewSize: size)
    let after = vp.viewToWorld(anchor, viewSize: size)
    #expect(before.distance(to: after) < 1e-9)
}

@Test func clampsZoom() {
    var vp = Viewport(center: .zero, zoom: 1)
    vp.zoom(by: 1000, around: .zero, viewSize: Vec2(x: 10, y: 10)); #expect(vp.zoom == 32)
    vp.zoom(by: 1e-6, around: .zero, viewSize: Vec2(x: 10, y: 10)); #expect(vp.zoom == 0.05)
}

@Test func panMovesCenterOppositeToDrag() {
    var vp = Viewport(center: .zero, zoom: 1)
    vp.pan(byView: Vec2(x: 160.0 / 25.4, y: 0))
    #expect(abs(vp.center.x + 1) < 1e-9 && vp.center.y == 0)
}

@Test func visibleRectCoversView() {
    let vp = Viewport(center: Vec2(x: 5, y: 5), zoom: 2)
    let size = Vec2(x: 800, y: 600)
    let r = vp.visibleWorldRect(viewSize: size)
    #expect(r.contains(vp.viewToWorld(.zero, viewSize: size)))
}

@Test func viewportCodableRoundTrip() throws {
    let vp = Viewport(center: Vec2(x: 1, y: 2), zoom: 3)
    let data = try JSONEncoder().encode(vp)
    #expect(try JSONDecoder().decode(Viewport.self, from: data) == vp)
}

@Test func sanitizesDecodedViewport() throws {
    func decode(_ json: String) throws -> Viewport {
        try JSONDecoder().decode(Viewport.self, from: Data(json.utf8))
    }
    #expect(try decode(#"{"center":{"x":0,"y":0},"zoom":0}"#).zoom == 1)
    #expect(try decode(#"{"center":{"x":0,"y":0},"zoom":-3}"#).zoom == 1)
    #expect(try decode(#"{"center":{"x":0,"y":0},"zoom":1000}"#).zoom == 32)
    #expect(try decode(#"{"center":{"x":0,"y":0},"zoom":0.001}"#).zoom == 0.05)
    let big = try decode(#"{"center":{"x":1e300,"y":-1e300},"zoom":2}"#)
    #expect(big.center == Vec2(x: 1e300, y: -1e300) && big.zoom == 2)
}
