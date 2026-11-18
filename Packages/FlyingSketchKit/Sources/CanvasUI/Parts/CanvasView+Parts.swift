import UIKit
import SketchCore
import PartsKit

/// `prefix` + the lowest positive integer not used by a label of the form `prefix` + digits; "" when `prefix` is empty.
func nextPartLabel(prefix: String, existing: some Sequence<String>) -> String {
    guard !prefix.isEmpty else { return "" }
    var used: Set<Int> = []
    for label in existing where label.hasPrefix(prefix) {
        let rest = label.dropFirst(prefix.count)
        if !rest.isEmpty, rest.allSatisfy(\.isASCII), rest.allSatisfy(\.isNumber), let n = Int(rest) { used.insert(n) }
    }
    var n = 1
    while used.contains(n) { n += 1 }
    return prefix + String(n)
}

private func partLabels(in doc: SketchDocument) -> [String] {
    doc.objects.compactMap { if case .part(let p) = $0 { p.label } else { nil } }
}

/// Copies of `objects` for insertion into `doc`: fresh ids, translated by `delta`. Wire ends stay attached only to
/// parts copied in the same batch (ids remapped); other attachments are cleared (position kept). Parts get the next
/// free label for their definition's prefix (`doc.parts`, else `definitions`); prefix "" keeps the label.
func cloned(_ objects: [SceneObject], by delta: Vec2, into doc: SketchDocument,
            definitions: [String: PartDefinition] = [:]) -> [SceneObject] {
    var newIDs: [ObjectID: ObjectID] = [:]
    var partIDs: Set<ObjectID> = []
    for o in objects {
        newIDs[o.id] = .new()
        if case .part = o { partIDs.insert(o.id) }
    }
    var labels = partLabels(in: doc)
    func remap(_ end: WireEnd) -> WireEnd {
        guard case .connector(let part, let connector)? = end.attachment else { return end }
        guard partIDs.contains(part), let id = newIDs[part] else { return WireEnd(position: end.position) }
        return WireEnd(position: end.position, attachment: .connector(part: id, connector: connector))
    }
    return objects.map { o in
        let copy = o.translated(by: delta).withID(newIDs[o.id]!)
        switch copy {
        case .part(var p):
            let prefix = (doc.parts[p.definitionKey] ?? definitions[p.definitionKey])?.labelPrefix ?? ""
            if !prefix.isEmpty {
                p.label = nextPartLabel(prefix: prefix, existing: labels)
                labels.append(p.label)
            }
            return .part(p)
        case .wire(var w):
            w.start = remap(w.start)
            w.end = remap(w.end)
            return .wire(w)
        default:
            return copy
        }
    }
}

/// Part placement, rotation and editing; part-aware move geometry.
extension CanvasView {
    // MARK: Place

    /// Embeds the definition (once) and its graphic asset, inserts an instance at the viewport centre (plug-snapped
    /// when a male connector lands within the snap radius of a female) and selects it. One edit "Add Part".
    public func placePart(_ part: LibraryPart) {
        let def = part.definition
        var doc = model.document
        var edits: [SceneEdit] = []
        if doc.parts[def.key] == nil {
            edits.append(.setDefinitions([def.key: def]))
            doc.parts[def.key] = def
        }
        if doc.assets[def.graphicAsset] == nil { model.addAssets([def.graphicAsset: part.graphic]) }
        var instance = PartInstance(definitionKey: def.key, center: currentViewport.center,
                                    label: nextPartLabel(prefix: def.labelPrefix, existing: partLabels(in: doc)),
                                    properties: def.properties)
        if let offset = plugSnapOffset(for: instance, in: doc, excluding: []) {
            instance.center = instance.center + offset
        }
        edits.append(.insert([.part(instance)], at: nil))
        model.perform(edits, actionName: "Add Part")
        selection.ids = [instance.id]
    }

    // MARK: Rotate / edit

    var selectionContainsParts: Bool { selectedObjects.contains(where: Self.isPart) }

    /// Quarter-turns every selected part around its own centre; attached wire ends follow. One edit "Rotate".
    public func rotateSelectedParts(clockwise: Bool) {
        var working = model.document
        var changed: [ObjectID: SceneObject] = [:]
        for case .part(let p) in selectedObjects {
            let objects = rotatePart(p.id, clockwise: clockwise, in: working)
            _ = SceneEdit.replace(objects).apply(to: &working)
            for o in objects { changed[o.id] = o }
        }
        guard !changed.isEmpty else { return }
        model.perform(.replace(Array(changed.values)), actionName: "Rotate")
    }

    /// Sets a part's label and properties. One edit "Edit Part"; nothing when unchanged.
    public func updatePartProperties(_ id: ObjectID, label: String, properties: [String: String]) {
        guard case .part(var p)? = model.document.objects.first(where: { $0.id == id }),
              p.label != label || p.properties != properties else { return }
        p.label = label
        p.properties = properties
        model.perform(.replace([.part(p)]), actionName: "Edit Part")
    }

    // MARK: Move geometry

    /// Selection plus every part carried by it (plugged into a moving part, transitively).
    func movingSet() -> Set<ObjectID> {
        let ids = selection.ids
        guard selectedObjects.contains(where: Self.isConnectable) else { return ids }
        return ids.union(carriedParts(by: ids, in: model.document))
    }

    private static func isPart(_ o: SceneObject) -> Bool {
        if case .part = o { true } else { false }
    }

    private static func isConnectable(_ o: SceneObject) -> Bool {
        switch o {
        case .part, .wire: true
        default: false
        }
    }

    /// Replacement objects for moving `moving` by `delta`: parts and wires via `moveParts` (carried parts follow,
    /// attached wire ends re-path), every other selected object translated.
    func movedObjects(_ moving: Set<ObjectID>, by delta: Vec2) -> [SceneObject] {
        let doc = model.document
        var result = selectedObjects.filter { !Self.isConnectable($0) }.map { $0.translated(by: delta) }
        if doc.objects.contains(where: { moving.contains($0.id) && Self.isConnectable($0) }) {
            result += moveParts(moving, by: delta, in: doc)
        }
        return result
    }

    /// Smallest plug-snap offset of any moved part after moving by `delta` (fixed parts only); zero if none.
    func plugSnap(_ moving: Set<ObjectID>, movedBy delta: Vec2) -> Vec2 {
        var tentative = model.document
        guard tentative.objects.contains(where: { moving.contains($0.id) && Self.isPart($0) }) else { return .zero }
        _ = SceneEdit.replace(moveParts(moving, by: delta, in: tentative)).apply(to: &tentative)
        var best: Vec2?
        for case .part(let p) in tentative.objects where moving.contains(p.id) {
            guard let offset = plugSnapOffset(for: p, in: tentative, excluding: moving) else { continue }
            if offset.length < (best?.length ?? .infinity) - 1e-9 { best = offset }
        }
        return best ?? .zero
    }
}
