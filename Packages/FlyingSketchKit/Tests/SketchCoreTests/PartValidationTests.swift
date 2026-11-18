import Foundation
import Testing
@testable import SketchCore

@Test func validDefinitionsPass() throws {
    try PartDefinition.fixtureResistor().validate()
    try PartDefinition.fixtureBreadboardMini().validate()
    var edge = PartDefinition.fixtureResistor()
    edge.size = Vec2(x: 10_000, y: 0.001)
    edge.connectors[0].position = Vec2(x: -10_000, y: 10_000)
    try edge.validate()
}

@Test func definitionValidationRejectsOutOfRangeGeometry() {
    let base = PartDefinition.fixtureResistor()
    var cases: [PartDefinition] = []
    for size in [Vec2(x: 0, y: 1), Vec2(x: 1, y: -1), Vec2(x: 10_000.5, y: 1), Vec2(x: .nan, y: 1), Vec2(x: 1, y: .infinity)] {
        var d = base; d.size = size; cases.append(d)
    }
    for v in [Vec2(x: 10_001, y: 0), Vec2(x: 0, y: -10_001), Vec2(x: .nan, y: 0), Vec2(x: 0, y: -.infinity)] {
        var p = base; p.connectors[0].position = v; cases.append(p)
        var o = base; o.connectors[0].leg?.origin = v; cases.append(o)
        var e = base; e.connectors[0].leg?.defaultEnd = v; cases.append(e)
    }
    var w = base; w.connectors[0].leg?.width = .nan; cases.append(w)
    for d in cases {
        #expect(throws: PartDefinitionError.geometryOutOfRange) { try d.validate() }
    }
    var unsafe = base
    unsafe.graphicAsset = "../x.svg"
    #expect(throws: PartDefinitionError.unsafeGraphicAsset) { try unsafe.validate() }
}
