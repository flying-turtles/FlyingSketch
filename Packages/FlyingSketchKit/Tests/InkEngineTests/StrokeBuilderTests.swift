import Testing
import SketchCore
@testable import InkEngine

private func sCurveSamples() -> [InkSample] {
    (0..<60).map { i in
        let t = Double(i)
        let x = t * 0.5
        let y = (i / 10) % 2 == 0 ? t * 0.3 : -t * 0.3 + 6
        return InkSample(position: Vec2(x: x, y: y), force: 0.3 + 0.01 * t, timestamp: 100 + t * 0.008)
    }
}

@Test func smoothingOffKeepsSamplePositions() {
    var b = StrokeBuilder(params: InkParams())
    let pts = sCurveSamples()
    pts.forEach { b.add($0) }
    #expect(b.committed.map(\.position) == pts.map(\.position))
    #expect(b.committed.map(\.pressure) == pts.map { $0.force! })
    #expect(b.committed.first?.time == 0)
}

@Test func smoothingOnMovesPositions() {
    var b = StrokeBuilder(params: InkParams(smoothing: true))
    let pts = sCurveSamples()
    pts.forEach { b.add($0) }
    #expect(b.committed.map(\.position) != pts.map(\.position))
}

@Test func fingerGetsDefaultPressure() {
    var b = StrokeBuilder(params: InkParams())
    b.add(InkSample(position: .zero, force: nil, timestamp: 0))
    #expect(b.committed[0].pressure == 0.5)
}

@Test func forceIsClamped() {
    var b = StrokeBuilder(params: InkParams())
    b.add(InkSample(position: .zero, force: 1.7, timestamp: 0))
    b.add(InkSample(position: .zero, force: -0.2, timestamp: 0.01))
    #expect(b.committed.map(\.pressure) == [1, 0])
}

@Test func predictedDoesNotMutateCommitted() {
    var b = StrokeBuilder(params: InkParams(smoothing: true))
    sCurveSamples().prefix(10).forEach { b.add($0) }
    let before = b.committed
    let pred = [InkSample(position: Vec2(x: 9, y: 9), force: 0.5, timestamp: 100.2),
                InkSample(position: Vec2(x: 10, y: 10), force: 0.5, timestamp: 100.21)]
    let all = b.points(predicted: pred)
    #expect(all.count == before.count + 2)
    #expect(b.committed == before)
    #expect(Array(all.prefix(before.count)) == before)
}
