import Foundation

/// Uniform grid hash over object bounds (world mm).
public struct SpatialIndex: Sendable {
    private struct Cell: Hashable, Sendable { var x: Int; var y: Int }

    public let cellSize: Double
    private var cells: [Cell: Set<ObjectID>] = [:]
    private var entries: [ObjectID: Rect] = [:]
    /// Objects spanning more than `maxCellSpan` cells per axis (or with non-finite bounds): checked on every query.
    private var oversize: Set<ObjectID> = []
    private static let maxCellSpan = 4096

    public init(cellSize: Double = 50) {
        self.cellSize = cellSize > 0 ? cellSize : 50
    }

    /// Re-inserting an existing id moves it.
    public mutating func insert(_ id: ObjectID, bounds: Rect) {
        remove(id)
        entries[id] = bounds
        guard let range = cellRange(bounds) else { oversize.insert(id); return }
        for cell in range { cells[cell, default: []].insert(id) }
    }

    public mutating func remove(_ id: ObjectID) {
        guard let bounds = entries.removeValue(forKey: id) else { return }
        guard let range = cellRange(bounds) else { oversize.remove(id); return }
        for cell in range {
            cells[cell]?.remove(id)
            if cells[cell]?.isEmpty == true { cells[cell] = nil }
        }
    }

    /// Ids whose bounds intersect `rect`.
    public func query(_ rect: Rect) -> Set<ObjectID> {
        var candidates = oversize
        if let range = cellRange(rect) {
            for cell in range {
                if let ids = cells[cell] { candidates.formUnion(ids) }
            }
        } else {
            // Huge query: scan everything.
            candidates = Set(entries.keys)
        }
        return candidates.filter { entries[$0]?.intersects(rect) == true }
    }

    /// nil when non-finite or spanning more than `maxCellSpan` cells per axis.
    private func cellRange(_ r: Rect) -> [Cell]? {
        let fx0 = (r.minX / cellSize).rounded(.down), fx1 = (r.maxX / cellSize).rounded(.down)
        let fy0 = (r.minY / cellSize).rounded(.down), fy1 = (r.maxY / cellSize).rounded(.down)
        let limit = Double(Int.max / 2)
        guard [fx0, fx1, fy0, fy1].allSatisfy({ $0.isFinite && abs($0) < limit }) else { return nil }
        let (x0, x1, y0, y1) = (Int(fx0), Int(fx1), Int(fy0), Int(fy1))
        guard x1 >= x0, y1 >= y0, x1 - x0 < Self.maxCellSpan, y1 - y0 < Self.maxCellSpan else { return nil }
        var out: [Cell] = []
        out.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for x in x0...x1 { for y in y0...y1 { out.append(Cell(x: x, y: y)) } }
        return out
    }
}
