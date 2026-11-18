import Testing
@testable import SketchCore

private func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
    Rect(origin: Vec2(x: x, y: y), size: Vec2(x: w, y: h))
}

@Test func spatialIndexQuery() {
    var idx = SpatialIndex()
    let a = ObjectID.new(), b = ObjectID.new()
    idx.insert(a, bounds: r(0, 0, 10, 10))
    idx.insert(b, bounds: r(500, 500, 10, 10))
    #expect(idx.query(r(-5, -5, 20, 20)) == [a])
    idx.remove(a)
    #expect(idx.query(r(-5, -5, 20, 20)).isEmpty)
    #expect(idx.query(r(0, 0, 1000, 1000)) == [b])
}

@Test func spatialIndexFiltersSameCellMisses() {
    var idx = SpatialIndex(cellSize: 50)
    let a = ObjectID.new()
    idx.insert(a, bounds: r(0, 0, 5, 5))
    #expect(idx.query(r(30, 30, 5, 5)).isEmpty)
}

@Test func spatialIndexReinsertMoves() {
    var idx = SpatialIndex()
    let a = ObjectID.new()
    idx.insert(a, bounds: r(0, 0, 10, 10))
    idx.insert(a, bounds: r(500, 500, 10, 10))
    #expect(idx.query(r(0, 0, 20, 20)).isEmpty)
    #expect(idx.query(r(495, 495, 20, 20)) == [a])
}

@Test func spatialIndexSpansCellsAndNegatives() {
    var idx = SpatialIndex(cellSize: 50)
    let a = ObjectID.new()
    idx.insert(a, bounds: r(-120, -10, 200, 20))
    #expect(idx.query(r(-110, 0, 1, 1)) == [a])
    #expect(idx.query(r(70, 0, 1, 1)) == [a])
    #expect(idx.query(r(0, 100, 5, 5)).isEmpty)
}

@Test func spatialIndexHugeBoundsDoNotTrap() {
    var idx = SpatialIndex(cellSize: 50)
    let a = ObjectID.new(), b = ObjectID.new(), c = ObjectID.new()
    idx.insert(a, bounds: r(-1e300, -1e300, 2e300, 2e300))
    idx.insert(b, bounds: r(0, 0, 1e9, 10))
    idx.insert(c, bounds: r(5, 5, 1, 1))
    #expect(idx.query(r(5, 5, 1, 1)) == [a, b, c])
    #expect(idx.query(r(5e8, 0, 1, 1)) == [a, b])
    #expect(idx.query(r(-1e300, -1e300, 2e300, 2e300)).count == 3)
    idx.remove(a)
    #expect(idx.query(r(5, 5, 1, 1)) == [b, c])
}
