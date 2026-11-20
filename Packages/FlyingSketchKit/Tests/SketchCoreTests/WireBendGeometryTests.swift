import Testing
@testable import SketchCore

private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

@Suite struct WireBendGeometryTests {
    let wire = Wire(start: WireEnd(position: Vec2(x: 0, y: 0), attachment: .connector(part: ObjectID.new(), connector: "a")),
                    end: WireEnd(position: Vec2(x: 10, y: 10)), bends: [Vec2(x: 10, y: 0)])

    @Test func movingBendReplacesOnlyThatBend() {
        let w = wire.movingBend(0, to: v(20, 5))
        #expect(w.bends == [v(20, 5)])
        #expect(w.start == wire.start)
        #expect(w.end == wire.end)
        #expect(w.id == wire.id)
    }

    @Test func insertingBendInFirstSegment() {
        #expect(wire.insertingBend(inSegment: 0, at: v(5, 0)).bends == [v(5, 0), v(10, 0)])
    }

    @Test func insertingBendInLastSegment() {
        #expect(wire.insertingBend(inSegment: 1, at: v(10, 5)).bends == [v(10, 0), v(10, 5)])
    }

    @Test func insertingBendOnStraightWire() {
        let straight = Wire(start: WireEnd(position: v(0, 0)), end: WireEnd(position: v(10, 0)))
        #expect(straight.insertingBend(inSegment: 0, at: v(5, 3)).bends == [v(5, 3)])
    }

    @Test func removingBend() {
        let w = wire.removingBend(0)
        #expect(w.bends == [])
        #expect(w.start == wire.start)
        #expect(w.end == wire.end)
    }

    @Test func segmentMidpoints() {
        #expect(wire.segmentMidpoints == [v(5, 0), v(10, 5)])
    }

    @Test func outOfRangeIsNoOp() {
        #expect(wire.movingBend(1, to: v(1, 1)) == wire)
        #expect(wire.movingBend(-1, to: v(1, 1)) == wire)
        #expect(wire.removingBend(-1) == wire)
        #expect(wire.removingBend(1) == wire)
        #expect(wire.insertingBend(inSegment: 2, at: v(1, 1)) == wire)
        #expect(wire.insertingBend(inSegment: -1, at: v(1, 1)) == wire)
    }
}
