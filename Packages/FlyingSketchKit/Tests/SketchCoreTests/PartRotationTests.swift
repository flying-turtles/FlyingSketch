import Foundation
import Testing
@testable import SketchCore

private func def20x10() -> PartDefinition {
    var d = PartDefinition.fixtureResistor()
    d.size = Vec2(x: 20, y: 10)
    d.connectors = [ConnectorDef(id: "p", name: "p", kind: .male, position: .zero)]
    return d
}

private func part(rotation: Double) -> PartInstance {
    PartInstance(definitionKey: def20x10().key, center: Vec2(x: 100, y: 50), rotation: rotation)
}

private func wrapper(_ json: String) -> FileWrapper {
    FileWrapper(directoryWithFileWrappers: ["document.json": FileWrapper(regularFileWithContents: Data(json.utf8))])
}

@Test func normalizedAngleWrapsAndSnaps() {
    #expect(normalizedAngle(-.pi / 2) == 3 * .pi / 2)
    #expect(normalizedAngle(2 * .pi) == 0)
    #expect(normalizedAngle(.pi / 2 + 1e-12) == .pi / 2)
    #expect(normalizedAngle(1.0) == 1.0)
}

@Test func quarterTurnsOfAngle() {
    #expect(quarterTurns(of: .pi) == 2)
    #expect(quarterTurns(of: 1.0) == nil)
}

@Test func worldPointExactAtQuarterTurns() {
    let d = def20x10()
    #expect(part(rotation: .pi / 2).worldPoint(.zero, in: d) == Vec2(x: 105, y: 40))
    #expect(part(rotation: .pi).worldPoint(.zero, in: d) == Vec2(x: 110, y: 55))
}

@Test func worldPointAtFreeAngle() {
    let d = def20x10()
    let p = part(rotation: .pi / 6)
    let expected = p.center + Vec2(x: -10, y: -5).rotated(by: .pi / 6)
    let w = p.worldPoint(.zero, in: d)
    #expect(w.distance(to: expected) < 1e-9)
    let q = Vec2(x: 3, y: 7)
    #expect(p.localPoint(p.worldPoint(q, in: d), in: d).distance(to: q) < 1e-9)
}

@Test func boundsOfRotatedPart() {
    var doc = SketchDocument()
    let d = def20x10()
    doc.parts[d.key] = d
    let p = part(rotation: .pi / 4)
    let b = bounds(of: .part(p), in: doc)
    let side = 30 * 0.5.squareRoot()
    #expect(abs(b.size.x - side) < 1e-6 && abs(b.size.y - side) < 1e-6)
    #expect(abs(b.minX + b.size.x / 2 - 100) < 1e-6 && abs(b.minY + b.size.y / 2 - 50) < 1e-6)
}

@Test func hitTestFollowsRotatedBody() {
    var doc = SketchDocument()
    let d = def20x10()
    doc.parts[d.key] = d
    let p = part(rotation: .pi / 4)
    let inside = p.center + Vec2(x: 9, y: 0).rotated(by: .pi / 4)
    #expect(hitTest(.part(p), point: inside, tolerance: 0.1, in: doc))
    #expect(!hitTest(.part(p), point: p.center + Vec2(x: 10, y: 10), tolerance: 0.1, in: doc))
}

@Test func rotatePartStepsQuarterTurn() throws {
    var doc = SketchDocument()
    let d = def20x10()
    doc.parts[d.key] = d
    let p = part(rotation: 0)
    doc.objects = [.part(p)]
    func rotation(_ r: [SceneObject]) throws -> Double {
        guard case .part(let q)? = r.first else { throw DocumentError.corrupt("no part") }
        return q.rotation
    }
    let once = rotatePart(p.id, clockwise: true, in: doc)
    var doc2 = doc
    _ = SceneEdit.replace(once).apply(to: &doc2)
    #expect(try rotation(rotatePart(p.id, clockwise: true, in: doc2)) == .pi)
    #expect(try rotation(rotatePart(p.id, clockwise: false, in: doc)) == 3 * .pi / 2)
}

@Test func legacyQuarterTurnsDecode() throws {
    let p = PartInstance(definitionKey: "k", center: .zero)
    var obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
    obj.removeValue(forKey: "rotation")
    obj["quarterTurns"] = 3
    let legacy = try JSONSerialization.data(withJSONObject: obj)
    let decoded = try JSONDecoder().decode(PartInstance.self, from: legacy)
    #expect(decoded.rotation == 3 * .pi / 2)
    let out = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
    #expect(out["rotation"] != nil)
    #expect(out["quarterTurns"] == nil)
}

/// Writer output as a JSON object, with every part dictionary (found under the enum case key) passed to `patch`.
private func packageJSON(_ doc: SketchDocument, version: Int, patch: (inout [String: Any]) -> Void) throws -> String {
    let w = try DocumentPackage.fileWrapper(for: doc)
    let data = try #require(w.fileWrappers?["document.json"]?.regularFileContents)
    var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    obj["formatVersion"] = version
    func walk(_ d: inout [String: Any]) {
        if d["definitionKey"] != nil { patch(&d); return }
        for (k, v) in d {
            if var sub = v as? [String: Any] { walk(&sub); d[k] = sub }
            else if var arr = v as? [[String: Any]] {
                for i in arr.indices { walk(&arr[i]) }
                d[k] = arr
            }
        }
    }
    walk(&obj)
    return String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
}

private func docWithPartRotation(_ r: Double) -> SketchDocument {
    var doc = SketchDocument.fixtureWithPartsAndWire()
    doc.objects = doc.objects.map { o in
        guard case .part(var p) = o else { return o }
        p.rotation = r
        return .part(p)
    }
    return doc
}

@Test func version2DocumentOpensAndSavesAs4() throws {
    let json = try packageJSON(docWithPartRotation(0), version: 2) {
        $0.removeValue(forKey: "rotation")
        $0["quarterTurns"] = 1
    }
    let read = try DocumentPackage.read(wrapper(json))
    #expect(read.formatVersion == 4)
    let rotations = read.objects.compactMap { o -> Double? in
        if case .part(let p) = o { return p.rotation } else { return nil }
    }
    #expect(rotations.count == 2 && rotations.allSatisfy { $0 == .pi / 2 })
    let again = try DocumentPackage.read(DocumentPackage.fileWrapper(for: read))
    #expect(again == read)
}

@Test func nonFiniteRotationRejected() throws {
    // JSONEncoder refuses NaN, so a hand-edited file is the only way in.
    let json = try packageJSON(docWithPartRotation(0.5), version: 3) { $0["rotation"] = "NaN" }
    #expect(throws: DocumentError.self) { try DocumentPackage.read(wrapper(json)) }
    var doc = docWithPartRotation(0.5)
    doc.objects = doc.objects.map { o in
        guard case .part(var p) = o else { return o }
        p.rotation = .infinity
        return .part(p)
    }
    #expect(throws: (any Error).self) { try DocumentPackage.fileWrapper(for: doc) }
}
