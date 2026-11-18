import Testing
@testable import SketchCore

@Test func snapRoundsToGrid() {
    #expect(snap(Vec2(x: 7.4, y: -2.6), grid: 5) == Vec2(x: 5, y: -5))
}

@Test func snapWithNonPositiveGridIsIdentity() {
    #expect(snap(Vec2(x: 1.3, y: 2.7), grid: 0) == Vec2(x: 1.3, y: 2.7))
}
