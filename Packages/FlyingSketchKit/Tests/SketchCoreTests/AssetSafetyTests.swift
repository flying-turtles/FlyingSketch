import Foundation
import Testing
@testable import SketchCore

@Test func safeAssetNameRules() {
    for ok in ["img1.png", "part-3ddcdacd93a134b0.svg", "A_b-c.d", "x", String(repeating: "a", count: 255)] {
        #expect(isSafeAssetName(ok), "\(ok)")
    }
    for bad in ["", ".", "..", ".hidden", "../escaped.txt", "../../escaped.txt", "a/b", "a\\b", "a b", "é.png",
                "a\u{0}b", String(repeating: "a", count: 256), "/abs"] {
        #expect(!isSafeAssetName(bad), "\(bad)")
    }
}

@Test func fileWrapperRejectsTraversalAssetName() throws {
    var doc = SketchDocument.fixtureWithEveryKind()
    doc.assets["../../escaped.txt"] = Data("x".utf8)
    #expect(throws: DocumentError.corrupt("unsafe asset name")) { try DocumentPackage.fileWrapper(for: doc) }
    // Nothing escapes the package when writing what would have been produced.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AssetSafety-\(UUID().uuidString)")
    let package = dir.appendingPathComponent("a/b/doc.flysketch")
    try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let w = try? DocumentPackage.fileWrapper(for: doc) { try w.write(to: package, originalContentsURL: nil) }
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a/b/escaped.txt").path))
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a/escaped.txt").path))
}

@Test func readIgnoresUnsafeAssetNames() throws {
    let doc = SketchDocument.fixtureWithEveryKind()
    let w = try DocumentPackage.fileWrapper(for: doc)
    let assets = try #require(w.fileWrappers?["assets"])
    for bad in [".hidden", "a b"] {
        let f = FileWrapper(regularFileWithContents: Data("x".utf8))
        f.preferredFilename = bad
        assets.addFileWrapper(f)
    }
    let back = try DocumentPackage.read(w)
    #expect(back.assets == doc.assets)
}

@MainActor @Test func addAssetsRejectsUnsafeNames() throws {
    let m = DocumentModel(document: .empty)
    #expect(throws: AssetNameError.unsafe("../x.png")) { try m.addAssets(["ok.png": Data([1]), "../x.png": Data([2])]) }
    #expect(m.document.assets.isEmpty) // all or nothing
    try m.addAssets(["ok.png": Data([1])])
    #expect(m.document.assets == ["ok.png": Data([1])])
}
