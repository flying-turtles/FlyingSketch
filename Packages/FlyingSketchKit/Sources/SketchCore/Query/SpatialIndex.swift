import Foundation

/// Uniform grid hash over object bounds (world mm).
public struct SpatialIndex: Sendable {
    private struct Cell: Hashable, Sendable { var x: Int; var y: Int }

    public let cellSize: Double
    private var cells: [Cell: Set<ObjectID>] = [:]
    private var entries: [ObjectID: Rect] = [:]

    public init(cellSize: Double = 50) {
        self.cellSize = cellSize > 0 ? cellSize : 50
    }

    /// Re-inserting an existing id moves it.
    public mutating func insert(_ id: ObjectID, bounds: Rect) {
        remove(id)
        entries[id] = bounds
        for cell in cellRange(bounds) { cells[cell, default: []].insert(id) }
    }

    public mutating func remove(_ id: ObjectID) {
        guard let bounds = entries.removeValue(forKey: id) else { return }
        for cell in cellRange(bounds) {
            cells[cell]?.remove(id)
            if cells[cell]?.isEmpty == true { cells[cell] = nil }
        }
    }

    /// Ids whose bounds intersect `rect`.
    public func query(_ rect: Rect) -> Set<ObjectID> {
        var candidates: Set<ObjectID> = []
        for cell in cellRange(rect) {
            if let ids = cells[cell] { candidates.formUnion(ids) }
        }
        return candidates.filter { entries[$0]?.intersects(rect) == true }
    }

    private func cellRange(_ r: Rect) -> [Cell] {
        let x0 = Int((r.minX / cellSize).rounded(.down)), x1 = Int((r.maxX / cellSize).rounded(.down))
        let y0 = Int((r.minY / cellSize).rounded(.down)), y1 = Int((r.maxY / cellSize).rounded(.down))
        var out: [Cell] = []
        out.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for x in x0...x1 { for y in y0...y1 { out.append(Cell(x: x, y: y)) } }
        return out
    }
}
