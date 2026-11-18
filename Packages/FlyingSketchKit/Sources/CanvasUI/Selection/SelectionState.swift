import Observation
import SketchCore

/// Currently selected objects. Observable so the app can show selection-dependent UI.
@Observable
public final class SelectionState {
    public var ids: Set<ObjectID> = []

    public init(ids: Set<ObjectID> = []) { self.ids = ids }
}
