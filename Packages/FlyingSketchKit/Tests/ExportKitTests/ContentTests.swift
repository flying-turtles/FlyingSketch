import Foundation
import CoreGraphics
import Testing
import SketchCore
@testable import ExportKit

@Test func emptyScopeThrows() {
    let doc = SketchDocument.fixtureThreeStrokes()
    #expect(throws: ExportError.nothingToExport) { try ExportContent.make(SketchDocument(), scope: .all) }
    #expect(throws: ExportError.nothingToExport) { try ExportContent.make(doc, scope: .selection([])) }
    #expect(throws: ExportError.nothingToExport) { try ExportContent.make(doc, scope: .selection([ObjectID.new()])) }
    #expect(ExportError.nothingToExport.localizedDescription == "Nothing to export.")
    #expect(ExportError.tooLarge.localizedDescription == "The drawing is too large to export.")
    #expect(ExportError.encodingFailed.localizedDescription == "The file couldn't be created.")
}

@Test func selectionKeepsZOrderAndAddsMargin() throws {
    let doc = SketchDocument.fixtureThreeStrokes()
    let ids = Set([doc.objects[2].id, doc.objects[0].id])
    let c = try ExportContent.make(doc, scope: .selection(ids))
    #expect(c.objects.map(\.id) == [doc.objects[0].id, doc.objects[2].id])
    let raw = try #require(contentBounds(of: c.objects, in: doc))
    #expect(c.bounds == raw.insetBy(-5))
}

@Test func textBoundsUseMeasuredWidthAndStayInsideRender() throws {
    var doc = SketchDocument()
    doc.objects = [.text(TextObject(text: "WWWW", position: Vec2(x: 0, y: 0), fontSize: 10))]
    let c = try ExportContent.make(doc, scope: .all)
    let size = TextLayout.measuredSize(try #require({ if case .text(let t) = doc.objects[0] { t } else { nil } }()))
    #expect(size.x > 24) // estimate was 24
    #expect(c.bounds.maxX >= size.x + 5 - 1e-6)
    let ppm = 10.0
    let img = render(c, pxPerMM: ppm)
    let data = img.dataProvider!.data! as Data
    var maxDarkX = -1
    for y in 0..<img.height { for x in 0..<img.width {
        let o = y * img.bytesPerRow + x * 4
        if data[o] < 200 { maxDarkX = max(maxDarkX, x) }
    } }
    #expect(maxDarkX >= 0)
    #expect(Double(img.width - 1 - maxDarkX) / ppm >= 4)
}

@Test func crlfSplitsLines() {
    #expect(TextLayout.lines(TextObject(text: "a\r\nb", position: .zero, fontSize: 5)).count == 2)
    #expect(TextLayout.lines(TextObject(text: "a\rb\nc", position: .zero, fontSize: 5)).count == 3)
}
