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
/// A joint is copied only when every anchor's object is copied too (anchors remapped, never partial); a group in
/// `groups` is copied (new id, remapped members) only when all its members are. Both move by `delta`.
func cloned(_ objects: [SceneObject], groups: [ObjectGroup] = [], by delta: Vec2, into doc: SketchDocument,
            definitions: [String: PartDefinition] = [:]) -> (objects: [SceneObject], groups: [ObjectGroup]) {
    let bodies = Set(objects.compactMap { o -> ObjectID? in
        switch o {
        case .wire, .joint: nil
        default: o.id
        }
    })
    let kept = objects.filter { o in
        guard case .joint(let j) = o else { return true }
        return !j.anchors.isEmpty && j.anchors.allSatisfy { bodies.contains($0.object) }
    }
    var newIDs: [ObjectID: ObjectID] = [:]
    var partIDs: Set<ObjectID> = []
    for o in kept {
        newIDs[o.id] = .new()
        if case .part = o { partIDs.insert(o.id) }
    }
    var labels = partLabels(in: doc)
    func remap(_ end: WireEnd) -> WireEnd {
        guard case .connector(let part, let connector)? = end.attachment else { return end }
        guard partIDs.contains(part), let id = newIDs[part] else { return WireEnd(position: end.position) }
        return WireEnd(position: end.position, attachment: .connector(part: id, connector: connector))
    }
    let copies = kept.map { o -> SceneObject in
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
        case .joint(var j):
            for i in j.anchors.indices { j.anchors[i].object = newIDs[j.anchors[i].object]! }
            return .joint(j)
        default:
            return copy
        }
    }
    let copiedGroups = groups.filter { $0.members.allSatisfy { bodies.contains($0) } }.map { g in
        ObjectGroup(members: g.members.map { newIDs[$0]! })
    }
    return (copies, copiedGroups)
}

/// Part placement, rotation and editing; part-aware move geometry.
extension CanvasView {
    // MARK: Place

    /// Embeds the definition (once) and its graphic asset, inserts an instance at the viewport centre (plug-snapped
    /// when a male connector lands within the snap radius of a female) and selects it. One edit "Add Part".
    /// A definition failing `validate()` is refused (no edit).
    public func placePart(_ part: LibraryPart) {
        let def = part.definition
        guard (try? def.validate()) != nil else { return }
        var doc = model.document
        var edits: [SceneEdit] = []
        if doc.parts[def.key] == nil {
            edits.append(.setDefinitions([def.key: def]))
            doc.parts[def.key] = def
        }
        if doc.assets[def.graphicAsset] == nil {
            guard (try? model.addAssets([def.graphicAsset: part.graphic])) != nil else { return }
        }
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
    /// Nothing when a selected part is anchored by a pin or the selection is pinned to outside (`selectionCanQuarterTurn`).
    public func rotateSelectedParts(clockwise: Bool) {
        guard selectionCanQuarterTurn else { return }
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

    /// `ids` plus everything carried by them (`PlugCarrier`): parts plugged into a moving part, transitively, each
    /// with its whole group. A pinned part or group outside `ids` is never carried (its pin holds), nor is what is
    /// plugged into it.
    func movingSet(_ ids: Set<ObjectID>) -> Set<ObjectID> {
        let doc = model.document
        guard doc.objects.contains(where: { ids.contains($0.id) && Self.isConnectable($0) }) else { return ids }
        return ids.union(PlugCarrier(doc).carried(by: ids))
    }

    private static func isPart(_ o: SceneObject) -> Bool {
        if case .part = o { true } else { false }
    }

    static func isConnectable(_ o: SceneObject) -> Bool {
        switch o {
        case .part, .wire: true
        default: false
        }
    }

    /// Replacement objects for moving `moving` by `delta`: parts and wires via `moveParts` (carried parts follow,
    /// attached wire ends re-path), every other object in `moving` (joints, members of carried groups) translated.
    /// Parts in `rigid` (directly dragged) move whole, legs included; only carried parts keep legs pinned.
    func movedObjects(_ moving: Set<ObjectID>, rigid: Set<ObjectID>, by delta: Vec2) -> [SceneObject] {
        let doc = model.document
        var result = doc.objects.filter { moving.contains($0.id) && !Self.isConnectable($0) }.map { $0.translated(by: delta) }
        if doc.objects.contains(where: { moving.contains($0.id) && Self.isConnectable($0) }) {
            result += moveParts(moving, by: delta, in: doc, rigid: rigid)
        }
        return result
    }

    /// Smallest plug-snap offset of any moved part after moving by `delta` (fixed parts only); zero if none.
    func plugSnap(_ moving: Set<ObjectID>, rigid: Set<ObjectID>, movedBy delta: Vec2) -> Vec2 {
        var tentative = model.document
        guard tentative.objects.contains(where: { moving.contains($0.id) && Self.isPart($0) }) else { return .zero }
        _ = SceneEdit.replace(moveParts(moving, by: delta, in: tentative, rigid: rigid)).apply(to: &tentative)
        var best: Vec2?
        for case .part(let p) in tentative.objects where moving.contains(p.id) {
            guard let offset = plugSnapOffset(for: p, in: tentative, excluding: moving) else { continue }
            if offset.length < (best?.length ?? .infinity) - 1e-9 { best = offset }
        }
        return best ?? .zero
    }
}
