import CoreGraphics
import Foundation
import Testing
import SketchCore
@testable import ExportKit

private let ppm = 10.0
private let accentHex = "#007aff"

private func svgString(_ c: ExportContent) -> String { String(decoding: SVGWriter.svg(c), as: UTF8.self) }

private func jointGroups(_ s: String) -> [String] {
    s.components(separatedBy: "<g class=\"joint\">").dropFirst().map { part in
        String(part.prefix(upTo: part.range(of: "</g>")?.lowerBound ?? part.endIndex))
    }
}

private func rect() -> SceneObject {
    .shape(ShapeObject(kind: .rectangle, start: Vec2(x: 0, y: 0), end: Vec2(x: 30, y: 10)))
}

@Test func drawOrderPutsJointsLastInDocumentOrder() {
    let a = Joint(position: Vec2(x: 5, y: 5)), b = Joint(position: Vec2(x: 20, y: 5), grounded: true)
    let r1 = rect(), r2 = rect()
    let objects: [SceneObject] = [.joint(a), r1, .joint(b), r2]
    let c = ExportContent(document: SketchDocument(objects: objects), objects: objects,
                          bounds: Rect(origin: .zero, size: Vec2(x: 40, y: 30)))
    #expect(c.drawOrder.map(\.id) == [r1.id, r2.id, a.id, b.id])
}

@Test func lockMarkIsDrawnInPNG() throws {
    let lock = Joint(kind: .fixed, position: Vec2(x: 20, y: 15), anchors: [], grounded: true)
    let bounds = Rect(origin: .zero, size: Vec2(x: 40, y: 30))
    let objects: [SceneObject] = [.joint(lock)]
    let c = ExportContent(document: SketchDocument(objects: objects), objects: objects, bounds: bounds)
    let img = render(c, pxPerMM: ppm)
    func at(_ x: Double, _ y: Double) -> (r: Double, g: Double, b: Double, a: Double) {
        pixel(img, mmX: x, mmY: y, bounds: bounds, pxPerMM: ppm)
    }
    let box = at(20 - JointGeometry.lockHalfWidth, 15) // left edge of the lock body
    #expect(box.r < 0.3 && box.b > 0.9) // accent blue, not the white background
    let bottom = at(20, 15 + JointGeometry.lockHalfHeight)
    #expect(bottom.r < 0.3 && bottom.b > 0.9)
    let shackleTop = at(20, 15 - JointGeometry.lockHalfHeight - JointGeometry.shackleRadius)
    #expect(shackleTop.r < 0.3 && shackleTop.b > 0.9)
    #expect(at(20, 15).r > 0.95) // inside the lock body stays background: no hinge ring or dot
    #expect(at(5, 5).r > 0.95)
}

@Test func groundMarkInSVG() {
    let c = ExportContent(document: SketchDocument(), objects: [.joint(Joint(position: Vec2(x: 20, y: 5), grounded: true))],
                          bounds: Rect(origin: .zero, size: Vec2(x: 40, y: 30)))
    let groups = jointGroups(svgString(c))
    #expect(groups.count == 1)
    let g = groups[0]
    #expect(g.components(separatedBy: "<circle").count == 3) // ring + dot
    #expect(g.components(separatedBy: "<polyline").count == 5) // base + three hatches
    #expect(g.contains("points=\"18.2 6.8 21.8 6.8\"")) // base line 1.8 mm below, 3.6 mm wide
    #expect(g.contains("stroke=\"\(accentHex)\""))
    #expect(g.contains("stroke-linecap=\"round\""))
    #expect(g.contains("stroke-width=\"0.3\""))
}

@Test func lockMarkInSVG() {
    let c = ExportContent(document: SketchDocument(),
                          objects: [.joint(Joint(kind: .fixed, position: Vec2(x: 5, y: 5), grounded: true))],
                          bounds: Rect(origin: .zero, size: Vec2(x: 40, y: 30)))
    let s = svgString(c)
    let g = jointGroups(s)[0]
    #expect(!s.contains("<circle"))
    #expect(g.components(separatedBy: "<polyline").count == 3) // box + shackle
    #expect(g.contains("points=\"3.8 4.1 6.2 4.1 6.2 5.9 3.8 5.9 3.8 4.1\"")) // 2.4 x 1.8 mm box
    #expect(g.contains("stroke=\"\(accentHex)\""))
    #expect(g.contains("stroke-linecap=\"round\""))
    #expect(g.contains("stroke-linejoin=\"round\""))
    #expect(g.contains("fill=\"none\""))
}

@Test func jointsAreDrawnButIgnoredByBOMAndNetlist() throws {
    var f = Fix()
    let r = f.add(f.res, at: Vec2(x: 10, y: 10), label: "R1", properties: ["resistance": "220Ω"])
    let bomBefore = BOMExporter.csv(f.doc), netBefore = NetlistExporter.csv(f.doc)
    let pin = Joint(position: Vec2(x: 10, y: 10), anchors: [JointAnchor(object: r, point: Vec2(x: 10, y: 10))], grounded: true)
    f.doc.objects.append(.joint(pin))

    let all = try ExportContent.make(f.doc, scope: .all)
    #expect(all.objects.contains { $0.id == pin.id })
    #expect(all.drawOrder.last?.id == pin.id)
    #expect(jointGroups(svgString(all)).count == 1)
    #expect(BOMExporter.csv(f.doc) == bomBefore)
    #expect(NetlistExporter.csv(f.doc) == netBefore)

    let onlyJoint = try ExportContent.make(f.doc, scope: .selection([pin.id]))
    #expect(onlyJoint.objects.map(\.id) == [pin.id])
    #expect(onlyJoint.bounds.size.x > 0 && onlyJoint.bounds.size.y > 0)
    #expect(jointGroups(svgString(onlyJoint)).count == 1)
}
