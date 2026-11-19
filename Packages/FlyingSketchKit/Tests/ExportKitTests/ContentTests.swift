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
