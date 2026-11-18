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
#endif
