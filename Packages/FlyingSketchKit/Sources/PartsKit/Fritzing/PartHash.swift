import CryptoKit
import Foundation
import SketchCore

public enum PartHash {
    /// First 16 hex chars of SHA-256 over canonical JSON (sorted keys) of the definition, with
    /// `versionHash` and `graphicAsset` blanked, followed by the graphic bytes.
    public static func versionHash(definitionWithoutHash: PartDefinition, graphic: Data) throws -> String {
        var def = definitionWithoutHash
        def.versionHash = ""
        def.graphicAsset = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var input = try encoder.encode(def)
        input.append(graphic)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
