#if DEBUG
import Foundation

extension SketchDocument {
    public static func fixtureWithEveryKind() -> SketchDocument {
        SketchDocument(
            objects: [
                .ink(fixtureStroke(origin: .zero, tool: .pen)),
                .shape(ShapeObject(kind: .arrow, start: Vec2(x: 0, y: 10), end: Vec2(x: 30, y: 40),
                                   strokeColor: RGBAColor(r: 1, g: 0, b: 0), fillColor: RGBAColor(r: 0, g: 1, b: 0, a: 0.5), lineWidth: 1.25)),
                .text(TextObject(text: "Hello ✏️", position: Vec2(x: -20, y: 5), fontSize: 8, rotation: 0.3)),
                .image(ImageObject(assetName: "img1.png", frame: Rect(origin: Vec2(x: 50, y: 50), size: Vec2(x: 40, y: 30)), rotation: -0.2)),
            ],
            viewport: Viewport(center: Vec2(x: 12.5, y: -7.25), zoom: 2),
            assets: ["img1.png": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])]
        )
    }

    public static func fixtureThreeStrokes() -> SketchDocument {
        SketchDocument(objects: (0..<3).map {
            .ink(fixtureStroke(origin: Vec2(x: Double($0) * 20, y: Double($0) * 5), tool: .pen))
        })
    }

    /// `strokes` short ink strokes on a square grid centred on the origin, `spacing` mm apart.
    public static func fixtureGrid(strokes: Int, spacing: Double) -> SketchDocument {
        let n = max(strokes, 0)
        let side = max(Int(Double(n).squareRoot().rounded(.up)), 1)
        let offset = Double(side - 1) / 2 * spacing
        let objects: [SceneObject] = (0..<n).map { i in
            let origin = Vec2(x: Double(i % side) * spacing - offset, y: Double(i / side) * spacing - offset)
            return .ink(fixtureStroke(origin: origin, tool: .pen))
        }
        return SketchDocument(objects: objects)
    }

    /// Resistor part + two-leg definition, a mini breadboard definition and a wire between them.
    public static func fixtureWithPartsAndWire() -> SketchDocument {
        let resistor = PartDefinition.fixtureResistor()
        let board = PartDefinition.fixtureBreadboardMini()
        let r = PartInstance(definitionKey: resistor.key, center: Vec2(x: 0, y: 0), label: "R1",
                             legEnds: ["a": Vec2(x: -7, y: 3)])
        let b = PartInstance(definitionKey: board.key, center: Vec2(x: 40, y: 0), rotation: .pi / 2)
        // Attached end sits exactly on its connector (consistent: reading reconciles nothing).
        let bEnd = connectorPositions(r, resistor)["b"]!
        let wire = Wire(start: WireEnd(position: bEnd, attachment: .connector(part: r.id, connector: "b")),
                        end: WireEnd(position: Vec2(x: 30, y: 5)), bends: [Vec2(x: 5, y: 5)])
        return SketchDocument(objects: [.part(r), .part(b), .wire(wire)],
                              assets: [resistor.graphicAsset: Data([1]), board.graphicAsset: Data([2])],
                              parts: [resistor.key: resistor, board.key: board])
    }

    private static func fixtureStroke(origin: Vec2, tool: InkTool) -> InkStroke {
        var points: [InkPoint] = []
        for i in 0..<5 {
            let t = Double(i)
            let pos = Vec2(x: origin.x + t * 0.5, y: origin.y + (i % 2 == 0 ? 0 : 0.25))
            points.append(InkPoint(position: pos, pressure: 0.2 + 0.15 * t,
                                   altitude: i == 0 ? nil : 0.8, azimuth: i == 0 ? nil : 1.1,
                                   time: t * 0.016))
        }
        return InkStroke(points: points, tool: tool, color: .black, baseWidth: 0.5)
    }
}

extension PartDefinition {
    private static let legColor = RGBAColor(r: 0.7, g: 0.7, b: 0.7)

    /// 2 male legged connectors 10.16 mm apart.
    public static func fixtureResistor() -> PartDefinition {
        func conn(_ id: String, x: Double, end: Vec2) -> ConnectorDef {
            let pos = Vec2(x: x, y: 1.25)
            return ConnectorDef(id: id, name: id, kind: .male, position: pos,
                                leg: LegSpec(origin: pos, defaultEnd: end, color: legColor, width: 0.6))
        }
        return PartDefinition(libraryID: "fixture-resistor", versionHash: "v1", title: "Resistor", family: "resistor",
                              labelPrefix: "R", size: Vec2(x: 10.16, y: 2.5), graphicAsset: "resistor.svg",
                              graphicKind: .svg,
                              connectors: [conn("a", x: 0, end: Vec2(x: -3, y: 1.25)),
                                           conn("b", x: 10.16, end: Vec2(x: 13.16, y: 1.25))])
    }

    /// Female 5x4 grid at 2.54 mm; one bus per column of 5 (ids `c<col>r<row>`).
    public static func fixtureBreadboardMini() -> PartDefinition {
        let pitch = 2.54
        var connectors: [ConnectorDef] = []
        var buses: [[String]] = []
        for col in 0..<4 {
            var bus: [String] = []
            for row in 0..<5 {
                let id = "c\(col)r\(row)"
                connectors.append(ConnectorDef(id: id, name: id, kind: .female,
                                               position: Vec2(x: 2.54 + Double(col) * pitch, y: 2.54 + Double(row) * pitch)))
                bus.append(id)
            }
            buses.append(bus)
        }
        return PartDefinition(libraryID: "fixture-breadboard-mini", versionHash: "v1", title: "Mini Breadboard",
                              family: "breadboard", labelPrefix: "BB", size: Vec2(x: 12.7, y: 15.24),
                              graphicAsset: "breadboard.svg", graphicKind: .svg, connectors: connectors, buses: buses)
    }

    /// 4 male pins in a row: VCC power, GND ground, SDA i2cSDA, SCL i2cSCL.
    public static func fixtureModule() -> PartDefinition {
        let pins: [(String, PinRole)] = [("VCC", .power), ("GND", .ground), ("SDA", .i2cSDA), ("SCL", .i2cSCL)]
        let connectors = pins.enumerated().map { i, pin in
            ConnectorDef(id: pin.0, name: pin.0, kind: .male, position: Vec2(x: 1.27 + Double(i) * 2.54, y: 1.27),
                         role: pin.1)
        }
        return PartDefinition(libraryID: "fixture-module", versionHash: "v1", title: "I2C Module", family: "module",
                              labelPrefix: "U", size: Vec2(x: 10.16, y: 12), graphicAsset: "module.png",
                              graphicKind: .png, connectors: connectors)
    }
}
#endif
