import Foundation
import Testing
import SketchCore
@testable import NetKit

/// Generated catalog in the repo (this file is Packages/FlyingSketchKit/Tests/NetKitTests/…).
private let catalogParts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("App/Catalog/parts")

private func catalogPart(_ id: String) throws -> PartDefinition {
    try JSONDecoder().decode(PartDefinition.self, from: Data(contentsOf: catalogParts.appendingPathComponent("\(id).json")))
}

@Test func netsOnFullBreadboardUnder50ms() throws {
    let board = try catalogPart("breadboard-full")
    let res = try catalogPart("resistor")
    var doc = SketchDocument()
    doc.parts = [board.key: board, res.key: res]

    let bb = PartInstance(definitionKey: board.key, center: Vec2(x: 0, y: 0), label: "BB1")
    doc.objects.append(.part(bb))
    let holes = connectorPositions(bb, board)
    let females = board.connectors.filter { $0.kind == .female }.map(\.id).sorted()
    try #require(females.count >= 120)

    // 60 resistors, both legs plugged into distinct holes.
    var resistors: [ObjectID] = []
    for i in 0..<60 {
        let a = try #require(holes[females[2 * i]]), b = try #require(holes[females[2 * i + 1]])
        let r = PartInstance(definitionKey: res.key, center: Vec2(x: 0, y: 100 + Double(i) * 5), label: "R\(i + 1)",
                             legEnds: ["connector0": a, "connector1": b])
        doc.objects.append(.part(r))
        resistors.append(r.id)
    }
    // 30 wires between resistors.
    for i in 0..<30 {
        let w = Wire(start: WireEnd(position: .zero, attachment: .connector(part: resistors[i], connector: "connector1")),
                     end: WireEnd(position: .zero, attachment: .connector(part: resistors[59 - i], connector: "connector0")))
        doc.objects.append(.wire(w))
    }
    #expect(contacts(in: doc).count == 120)

    let clock = ContinuousClock()
    var best = Duration.seconds(1)
    var result: [Net] = []
    for _ in 0..<5 {
        let t = clock.measure { result = nets(in: doc) }
        best = min(best, t)
    }
    #expect(!result.isEmpty)
    print("nets(in:) full breadboard + 60 resistors + 30 wires: \(best)")
    #expect(best < .milliseconds(50))
}
