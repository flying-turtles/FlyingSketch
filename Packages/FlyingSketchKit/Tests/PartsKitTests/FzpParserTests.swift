import Foundation
import Testing
import SketchCore
@testable import PartsKit

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/fritzing/\(name)", withExtension: nil))
    return try Data(contentsOf: url)
}

private func resistor() throws -> PartDefinition {
    try FzpParser.parse(fzp: fixture("resistor.fzp"), breadboardSVG: fixture("resistor_220.svg"),
                        svgFileName: "resistor_220.svg")
}

/// Stored (method 0) zip writer for building importer inputs.
private func makeZip(_ files: [(String, Data)]) -> Data {
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }
    var out = Data(), central = Data()
    for (name, data) in files {
        let crc = Int(ZipReader.crc32(data)), nameBytes = Array(name.utf8)
        let offset = out.count
        out.append(contentsOf: le32(0x0403_4b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc)
            + le32(data.count) + le32(data.count) + le16(nameBytes.count) + le16(0) + nameBytes)
        out.append(data)
        central.append(contentsOf: le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            + le32(crc) + le32(data.count) + le32(data.count) + le16(nameBytes.count) + le16(0) + le16(0)
            + le16(0) + le16(0) + le32(0) + le32(offset) + nameBytes)
    }
    let cdOffset = out.count
    out.append(central)
    out.append(contentsOf: le32(0x0605_4b50) + le16(0) + le16(0) + le16(files.count) + le16(files.count)
        + le32(central.count) + le32(cdOffset) + le16(0))
    return out
}

@Suite struct FzpParserTests {
    @Test func parsesResistorWithLegs() throws {
        let d = try resistor()
        #expect(d.libraryID == "ResistorModuleID")
        #expect(d.title == "220 \u{2126} Resistor")
        #expect(d.family == "Resistor")
        #expect(d.labelPrefix == "R")
        #expect(d.tags.contains("Resistor"))
        #expect(d.properties["Resistance"] == "220")
        #expect(d.connectors.count == 2)
        #expect(d.graphicKind == .svg)
        #expect(d.graphicAsset == "part-\(d.versionHash).svg")
        #expect(d.versionHash.count == 16)
        let mm = 0.42917 * 25.4 / 42.917   // viewBox user unit
        #expect(abs(d.size.x - 0.42917 * 25.4) < 1e-6)
        for c in d.connectors {
            #expect(c.kind == .male)
            let leg = try #require(c.leg)
            let len = hypot(leg.defaultEnd.x - leg.origin.x, leg.defaultEnd.y - leg.origin.y)
            #expect(abs(len - 1.455 * mm) < 1e-6)
            #expect(abs(leg.color.r - 0x8C / 255.0) < 1e-9)
            #expect(abs(leg.width - 2.91 * mm) < 1e-6)
        }
        // connector0pin rect center: (1.0, 4.09) user units
        let p = d.connectors[0].position
        #expect(abs(p.x - 1.0 * mm) < 1e-6)
    }

    @Test func parsesBreadboardBuses() throws {
        let d = try FzpParser.parse(fzp: fixture("miniBreadboard.fzp"), breadboardSVG: fixture("miniBreadboard.svg"),
                                    svgFileName: "miniBreadboard.svg")
        let fzp = try String(contentsOf: #require(Bundle.module.url(forResource: "Fixtures/fritzing/miniBreadboard.fzp", withExtension: nil)),
                             encoding: .utf8)
        #expect(d.buses.count == fzp.components(separatedBy: "<bus ").count - 1)
        let row = try #require(d.buses.first { $0.contains("A1") })
        #expect(Set(row) == ["A1", "B1", "C1", "D1", "E1"])
        #expect(d.connectors.allSatisfy { $0.leg == nil })
        let a1 = try #require(d.connectors.first { $0.id == "A1" })
        let b1 = try #require(d.connectors.first { $0.id == "B1" })
        #expect(abs(a1.position.x - b1.position.x) < 1e-6)
        #expect(b1.position.y > a1.position.y)
    }

    @Test func importsFzpzModule() throws {
        let (d, graphic) = try FzpzImporter.importPart(fixture("AdafruitAHT20.fzpz"))
        #expect(d.libraryID == "adafruit_873096366da6049bbe1203fd0a4ee811_1")
        #expect(d.connectors.count == 12)
        #expect(Set(["VCC", "GND", "SCL", "SDA"]).isSubset(of: Set(d.connectors.map(\.name))))
        #expect(d.connectors.contains { $0.name == "SDA" && $0.role == .i2cSDA })
        #expect(d.connectors.contains { $0.name == "GND" && $0.role == .ground })
        #expect(d.buses.count == 4)
        #expect(d.labelPrefix == "U")
        #expect(!graphic.isEmpty)
        #expect(d.versionHash == PartHash.versionHash(definitionWithoutHash: d, graphic: graphic))
    }

    @Test func missingConnectorGeometryIsAnError() throws {
        let svg = try #require(String(data: fixture("resistor_220.svg"), encoding: .utf8))
            .replacingOccurrences(of: "id=\"connector1pin\"", with: "id=\"gone\"")
        #expect(throws: PartImportError.missingConnectorGeometry("connector1")) {
            try FzpParser.parse(fzp: fixture("resistor.fzp"), breadboardSVG: Data(svg.utf8), svgFileName: "x.svg")
        }
        let noLeg = svg.replacingOccurrences(of: "id=\"gone\"", with: "id=\"connector1pin\"")
            .replacingOccurrences(of: "id=\"connector1leg\"", with: "id=\"gone\"")
        #expect(throws: PartImportError.missingConnectorGeometry("connector1")) {
            try FzpParser.parse(fzp: fixture("resistor.fzp"), breadboardSVG: Data(noLeg.utf8), svgFileName: "x.svg")
        }
    }

    @Test func importRejectsBrokenParts() throws {
        let fzp = try fixture("resistor.fzp"), svg = try fixture("resistor_220.svg")
        #expect(throws: PartImportError.noFzp) { try FzpzImporter.importPart(makeZip([("a.svg", svg)])) }
        #expect(throws: PartImportError.multipleFzp) {
            try FzpzImporter.importPart(makeZip([("a.fzp", fzp), ("b.fzp", fzp)]))
        }
        #expect(throws: PartImportError.missingBreadboardSVG("resistor_220.svg")) {
            try FzpzImporter.importPart(makeZip([("part.r.fzp", fzp)]))
        }
        #expect(throws: PartImportError.self) { try FzpzImporter.importPart(Data("nope".utf8)) }
        let ok = try FzpzImporter.importPart(makeZip([("part.r.fzp", fzp), ("svg.breadboard.RESISTOR_220.svg", svg)]))
        #expect(ok.definition.connectors.count == 2)
    }

    @Test func rejectsEntitiesAndOversizedInput() throws {
        let fzp = try fixture("resistor.fzp"), svg = try fixture("resistor_220.svg")
        let bomb = Data("<?xml version=\"1.0\"?><!DOCTYPE m [<!ENTITY a \"aaaa\">]><module moduleId=\"x\"/>".utf8)
        #expect(throws: PartImportError.invalidFzp("entity declarations not allowed")) {
            try FzpParser.parse(fzp: bomb, breadboardSVG: svg, svgFileName: "x.svg")
        }
        let svgBomb = Data("<!DOCTYPE svg [<!ENTITY a \"aaaa\">]><svg width=\"1\" height=\"1\"/>".utf8)
        #expect(throws: PartImportError.invalidSVG("entity declarations not allowed")) {
            try FzpParser.parse(fzp: fzp, breadboardSVG: svgBomb, svgFileName: "x.svg")
        }
        #expect(throws: PartImportError.invalidFzp("too large")) {
            try FzpParser.parse(fzp: Data(count: 1024 * 1024 + 1), breadboardSVG: svg, svgFileName: "x.svg")
        }
        #expect(throws: PartImportError.invalidSVG("too large")) {
            try FzpParser.parse(fzp: fzp, breadboardSVG: Data(count: 5 * 1024 * 1024 + 1), svgFileName: "x.svg")
        }
        #expect(throws: PartImportError.invalidSVG("notSVG")) {
            try FzpParser.parse(fzp: fzp, breadboardSVG: Data("<html/>".utf8), svgFileName: "x.svg")
        }
    }

    @Test func hashChangesWithGraphic() throws {
        let d = try resistor()
        let a = PartHash.versionHash(definitionWithoutHash: d, graphic: Data("a".utf8))
        let b = PartHash.versionHash(definitionWithoutHash: d, graphic: Data("b".utf8))
        #expect(a != b)
        #expect(a == PartHash.versionHash(definitionWithoutHash: d, graphic: Data("a".utf8)))
        var d2 = d; d2.title = "other"
        #expect(a != PartHash.versionHash(definitionWithoutHash: d2, graphic: Data("a".utf8)))
        // independent of the hash/asset fields themselves
        var d3 = d; d3.versionHash = "zzz"; d3.graphicAsset = "q"
        #expect(a == PartHash.versionHash(definitionWithoutHash: d3, graphic: Data("a".utf8)))
    }

    @Test(arguments: [
        ("GND", PinRole.ground), ("VSS", .ground), ("AGND", .ground),
        ("3V3", .power), ("3.3V", .power), ("5V", .power), ("VIN", .power), ("VCC", .power), ("VDD", .power),
        ("SDA", .i2cSDA), ("SCL", .i2cSCL),
        ("MOSI", .spi), ("MISO", .spi), ("SCK", .spi), ("SCLK", .spi), ("CS", .spi),
        ("TX", .uart), ("RX", .uart), ("TXD", .uart), ("U0TXD", .uart),
        ("GPIO21", .digital), ("D13", .digital), ("IO4", .digital),
        ("A0", .analog), ("ADC", .analog),
    ])
    func rolesFromNames(name: String, role: PinRole) {
        #expect(FzpParser.role(forName: name) == role)
    }

    @Test func unknownNamesHaveNoRole() {
        #expect(FzpParser.role(forName: "Pin 0") == nil)
        #expect(FzpParser.role(forName: "RST") == nil)
    }
}
