import SketchCore
import PartsKit

/// Library versions vs the frozen definitions embedded in the document.
extension CanvasView {
    /// Embedded definitions used by at least one instance whose library part has a different `versionHash`,
    /// each paired with the library's version. Sorted by title, then key.
    public func outdatedParts(comparedTo library: [LibraryPart]) -> [(current: PartDefinition, newer: LibraryPart)] {
        Self.outdatedParts(in: model.document, comparedTo: library)
    }

    static func outdatedParts(in doc: SketchDocument, comparedTo library: [LibraryPart])
        -> [(current: PartDefinition, newer: LibraryPart)] {
        let byID = Dictionary(library.map { ($0.definition.libraryID, $0) }, uniquingKeysWith: { first, _ in first })
        var used: Set<String> = []
        for case .part(let p) in doc.objects { used.insert(p.definitionKey) }
        return doc.parts.values
            .filter { used.contains($0.key) }
            .sorted { ($0.title, $0.key) < ($1.title, $1.key) }
            .compactMap { def in
                guard let newer = byID[def.libraryID], newer.definition.versionHash != def.versionHash else { return nil }
                return (def, newer)
            }
    }

    /// Repoints every instance of an older version of `libraryID` to `newer`. Legs on vanished connectors reset to
    /// their default end (others kept), wires follow surviving connectors and go free on vanished ones, labels and
    /// properties stay, old definitions are dropped. One edit "Update Part"; nothing when nothing is outdated.
    public func updatePart(libraryID: String, to newer: LibraryPart) {
        let new = newer.definition
        guard new.libraryID == libraryID else { return }
        let oldKeys = Set(model.document.parts.filter { $0.value.libraryID == libraryID && $0.key != new.key }.keys)
        guard !oldKeys.isEmpty else { return }

        var working = model.document
        var edits: [SceneEdit] = []
        func run(_ edit: SceneEdit) {
            edits.append(edit)
            _ = edit.apply(to: &working)
        }
        if working.parts[new.key] == nil { run(.setDefinitions([new.key: new])) }
        if working.assets[new.graphicAsset] == nil {
            guard (try? model.addAssets([new.graphicAsset: newer.graphic])) != nil else { return }
        }

        let connectorIDs = Set(new.connectors.map(\.id))
        var repointed: [SceneObject] = []
        for case .part(var p) in working.objects where oldKeys.contains(p.definitionKey) {
            p.definitionKey = new.key
            p.legEnds = p.legEnds.filter { connectorIDs.contains($0.key) }
            repointed.append(.part(p))
        }
        if !repointed.isEmpty { run(.replace(repointed)) }
        let wires = reconcileWires(in: working)
        if !wires.isEmpty { run(.replace(wires)) }
        run(.setDefinitions(Dictionary(uniqueKeysWithValues: oldKeys.map { ($0, PartDefinition?.none) })))
        model.perform(edits, actionName: "Update Part")
    }
}
