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

/// Two wires from two different GND pins of the S3 board to two otherwise unconnected resistors: the board's ground
/// bus joins them into one net.
@Test func wiringTwoS3GroundPinsYieldsOneNet() throws {
    let mcu = try catalogPart("esp32-s3-devkitc-1")
    let res = try catalogPart("resistor")
    let grounds = mcu.connectors.filter { $0.role == .ground }
    try #require(grounds.count >= 2)
    let board = PartInstance(definitionKey: mcu.key, center: .zero, label: "U1")
    let r1 = PartInstance(definitionKey: res.key, center: Vec2(x: 60, y: 0), label: "R1")
    let r2 = PartInstance(definitionKey: res.key, center: Vec2(x: 60, y: 30), label: "R2")
    func wire(_ pin: String, _ r: PartInstance) -> Wire {
        Wire(start: WireEnd(position: .zero, attachment: .connector(part: board.id, connector: pin)),
             end: WireEnd(position: .zero, attachment: .connector(part: r.id, connector: "connector0")))
    }
    let doc = SketchDocument(objects: [.part(board), .part(r1), .part(r2),
                                       .wire(wire(grounds[0].id, r1)), .wire(wire(grounds[1].id, r2))],
                             parts: [mcu.key: mcu, res.key: res])
    let groundNets = nets(in: doc).filter { net in grounds.contains { net.members.contains(ConnectorRef(part: board.id, connector: $0.id)) } }
    #expect(groundNets.count == 1)
    let net = try #require(groundNets.first)
    #expect(net.members.contains(ConnectorRef(part: r1.id, connector: "connector0")))
    #expect(net.members.contains(ConnectorRef(part: r2.id, connector: "connector0")))
}
