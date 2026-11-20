/// One undoable change to a document's object list. Every edit's `apply` returns its exact inverse.
public enum SceneEdit: Sendable {
    /// Inserts at `index` (clamped); `nil` = top of z-order.
    case insert([SceneObject], at: Int?)
    case remove(Set<ObjectID>)
    /// Replaces objects in place, matched by id (position in z-order unchanged).
    case replace([SceneObject])
    /// Inverse of a multi-object `remove`: puts each object back at its original index.
    /// A single `insert(_, at:)` cannot restore non-adjacent removals, hence this fourth case.
    case reinsert([IndexedObject])
    /// Adds/replaces definitions by key; `nil` removes. Inverse restores previous values (including absence).
    case setDefinitions([String: PartDefinition?])
    /// Replaces the whole groups table. Inverse restores the previous table.
    case setGroups([ObjectGroup])

    public struct IndexedObject: Sendable {
        public var index: Int
        public var object: SceneObject
        public init(index: Int, object: SceneObject) {
            self.index = index
            self.object = object
        }
    }

    /// Applies the edit and returns its inverse.
    public func apply(to doc: inout SketchDocument) -> SceneEdit {
        switch self {
        case .insert(let objects, let at):
            let index = min(max(at ?? doc.objects.count, 0), doc.objects.count)
            doc.objects.insert(contentsOf: objects, at: index)
            return .remove(Set(objects.map(\.id)))

        case .remove(let ids):
            var removed: [IndexedObject] = []
            var kept: [SceneObject] = []
            kept.reserveCapacity(doc.objects.count)
            for (i, o) in doc.objects.enumerated() {
                if ids.contains(o.id) { removed.append(IndexedObject(index: i, object: o)) } else { kept.append(o) }
            }
            doc.objects = kept
            return .reinsert(removed)

        case .reinsert(let items):
            // Ascending order: each original index is valid once all lower ones are back.
            for item in items.sorted(by: { $0.index < $1.index }) {
                doc.objects.insert(item.object, at: min(max(item.index, 0), doc.objects.count))
            }
            return .remove(Set(items.map(\.object.id)))

        case .replace(let replacements):
            var previous: [SceneObject] = []
            let byID = Dictionary(replacements.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            for i in doc.objects.indices {
                if let new = byID[doc.objects[i].id] {
                    previous.append(doc.objects[i])
                    doc.objects[i] = new
                }
            }
            return .replace(previous)

        case .setDefinitions(let changes):
            var previous: [String: PartDefinition?] = [:]
            for (key, new) in changes {
                previous[key] = .some(doc.parts[key])
                doc.parts[key] = new
            }
            return .setDefinitions(previous)

        case .setGroups(let groups):
            let previous = doc.groups
            doc.groups = groups
            return .setGroups(previous)
        }
    }
}
