import Foundation
import Testing
@testable import SketchCore

@Test func roundTripsAllObjectKindsAndAssets() throws {
    let doc = SketchDocument.fixtureWithEveryKind()
    let back = try DocumentPackage.read(DocumentPackage.fileWrapper(for: doc))
    #expect(back == doc)
}

@Test func writesExpectedLayout() throws {
    let w = try DocumentPackage.fileWrapper(for: .fixtureWithEveryKind())
    #expect(w.fileWrappers?["document.json"] != nil)
    #expect(w.fileWrappers?["assets"]?.fileWrappers?["img1.png"] != nil)
}

@Test func rejectsNewerFormatVersion() {
    let w = FileWrapper(directoryWithFileWrappers: ["document.json": FileWrapper(regularFileWithContents: Data(#"{"formatVersion":99,"objects":[]}"#.utf8))])
    #expect(throws: DocumentError.unsupportedVersion(99)) { try DocumentPackage.read(w) }
}

@Test func rejectsCorruptJSON() {
    let w = FileWrapper(directoryWithFileWrappers: ["document.json": FileWrapper(regularFileWithContents: Data("{nope".utf8))])
    #expect(throws: DocumentError.self) { try DocumentPackage.read(w) }
}

@Test func rejectsMissingDocumentJSON() {
    #expect(throws: DocumentError.missingDocumentJSON) { try DocumentPackage.read(FileWrapper(directoryWithFileWrappers: [:])) }
}

@Test func rejectsUnknownObjectType() {
    let json = #"{"formatVersion":1,"objects":[{"type":"bogus"}],"viewport":{"center":{"x":0,"y":0},"zoom":1}}"#
    let w = FileWrapper(directoryWithFileWrappers: ["document.json": FileWrapper(regularFileWithContents: Data(json.utf8))])
    #expect(throws: DocumentError.self) { try DocumentPackage.read(w) }
}

@Test func emptyDocumentRoundTrips() throws {
    let back = try DocumentPackage.read(DocumentPackage.fileWrapper(for: .empty))
    #expect(back == .empty && SketchDocument.empty == SketchDocument())
}

@Test func sceneObjectJSONIsFlatWithTypeKey() throws {
    let obj = SceneObject.text(TextObject(text: "x", position: .zero))
    let data = try JSONEncoder().encode(obj)
    let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(dict["type"] as? String == "text" && dict["text"] as? String == "x")
}

@Test func translateAndWithID() {
    let obj = SceneObject.shape(ShapeObject(kind: .line, start: .zero, end: Vec2(x: 1, y: 1)))
    let moved = obj.translated(by: Vec2(x: 2, y: 3))
    guard case .shape(let s) = moved else { Issue.record("kind changed"); return }
    #expect(s.start == Vec2(x: 2, y: 3) && s.end == Vec2(x: 3, y: 4))
    let id = ObjectID.new()
    #expect(obj.withID(id).id == id)
}

@Test func gridFixtureCountAndCentering() {
    let doc = SketchDocument.fixtureGrid(strokes: 100, spacing: 10)
    #expect(doc.objects.count == 100)
    let pts = doc.objects.compactMap { o -> Vec2? in if case .ink(let s) = o { s.points.first?.position } else { nil } }
    let r = Rect.bounding(pts)!
    #expect(abs((r.minX + r.maxX) / 2) < 1 && abs((r.minY + r.maxY) / 2) < 1)
}

@Test func rejectsAbsurdCoordinates() {
    func wrapper(_ obj: String, center: String = "0") -> FileWrapper {
        let json = #"{"formatVersion":1,"objects":[\#(obj)],"viewport":{"center":{"x":\#(center),"y":0},"zoom":1}}"#
        return FileWrapper(directoryWithFileWrappers: ["document.json": FileWrapper(regularFileWithContents: Data(json.utf8))])
    }
    let id = #""id":"00000000-0000-0000-0000-000000000001""#
    let huge = #"{"type":"shape",\#(id),"kind":"line","start":{"x":1e300,"y":0},"end":{"x":0,"y":0},"strokeColor":{"r":0,"g":0,"b":0,"a":1},"lineWidth":1}"#
    #expect(throws: DocumentError.self) { try DocumentPackage.read(wrapper(huge)) }
    let negFont = #"{"type":"text",\#(id),"text":"x","position":{"x":0,"y":0},"fontSize":-3,"rotation":0,"color":{"r":0,"g":0,"b":0,"a":1}}"#
    #expect(throws: DocumentError.self) { try DocumentPackage.read(wrapper(negFont)) }
    #expect(throws: DocumentError.self) { try DocumentPackage.read(wrapper("", center: "1e300")) }
    #expect(throws: Never.self) { try DocumentPackage.read(wrapper("")) }
}
