import Testing
import SketchCore
@testable import ExportKit

@Test func csvQuotesSpecialFields() {
    #expect(CSV.field("plain") == "plain")
    #expect(CSV.field("a,\"b\"\nc") == "\"a,\"\"b\"\"\nc\"")
    #expect(CSV.document([["a", "b"], ["1", "2"]]) == "\u{FEFF}a,b\r\n1,2\r\n")
}

@Test func bomGroupsByTitleAndProperties() {
    var f = Fix()
    f.add(f.res, label: "R10", properties: ["resistance": "220Ω"])
    f.add(f.res, label: "R1", properties: ["resistance": "220Ω", "family": "x"])
    f.add(f.res, label: "R2", properties: ["resistance": "220Ω", "tol": ""])
    f.add(f.res, label: "R3", properties: ["resistance": "1kΩ"])
    f.add(f.board, label: "BB1")
    f.add(f.module, label: "U1, main")
    #expect(BOMExporter.csv(f.doc) == "\u{FEFF}Quantity,Title,Labels,Properties\r\n" +
        "1,I2C Module,\"U1, main\",\r\n" +
        "1,Mini Breadboard,BB1,\r\n" +
        "1,Resistor,R3,resistance=1kΩ\r\n" +
        "3,Resistor,R1 R2 R10,resistance=220Ω\r\n")
}

@Test func bomUnknownDefinition() {
    var f = Fix()
    f.doc.objects.append(.part(PartInstance(definitionKey: "x@1", center: .zero, label: "Q1")))
    #expect(BOMExporter.csv(f.doc).hasSuffix("1,Unknown part (x@1),Q1,\r\n"))
}

@Test func netlistUsesLabelDotPinAndSkipsBreadboards() {
    var f = Fix()
    // breadboard centre (0,0): c0r0 at (-3.81,-5.08), c0r2 at (-3.81,0)
    f.add(f.board, at: .zero, label: "BB1")
    let r1 = f.add(f.res, at: Vec2(x: 100, y: 0), label: "R1")
    let r2 = f.add(f.res, at: Vec2(x: 100, y: 50), label: "R2", legEnds: ["b": Vec2(x: -3.81, y: 0)])
    // module origin = centre - (5.08, 6); VCC local (1.27,1.27) lands on c0r0
    f.add(f.module, at: Vec2(x: 0, y: -0.35), label: "U1")
    let r3 = f.add(f.res, at: Vec2(x: 100, y: 100), label: "R3")
    f.wire((r1, "b"), (r2, "a"))
    f.wire((r3, "a"), nil)  // dangling: its own 1-pin net, omitted; consumes N2
    #expect(NetlistExporter.csv(f.doc) == "\u{FEFF}Net,Pins\r\nVCC,R2.b U1.VCC\r\nN3,R1.b R2.a\r\n")
}
