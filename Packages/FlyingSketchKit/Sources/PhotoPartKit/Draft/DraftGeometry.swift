import Foundation
import SketchCore

/// Pin pitch in mm.
private let pinPitchMM = 2.54

/// Rounds the anchor-relative offset to multiples of 2.54 mm on the output axes.
public func snapToPinGrid(_ outputPoint: Vec2, anchor: Vec2, mmPerPixel: Double) -> Vec2 {
    let pitch = pinPitchMM / mmPerPixel
    guard pitch.isFinite, pitch > 0 else { return outputPoint }
    let d = outputPoint - anchor
    return Vec2(x: anchor.x + (d.x / pitch).rounded() * pitch,
                y: anchor.y + (d.y / pitch).rounded() * pitch)
}

extension PhotoPartDraft {
    public func outputSize() -> Vec2 {
        crop.quarterTurns % 2 == 0 ? crop.size : Vec2(x: crop.size.y, y: crop.size.x)
    }

    private var rotation: Double { Double(crop.quarterTurns) * .pi / 2 - crop.angle }

    public func toOutput(_ p: Vec2) -> Vec2 {
        (p - crop.center).rotated(by: rotation) + outputSize() / 2
    }

    public func toSource(_ p: Vec2) -> Vec2 {
        (p - outputSize() / 2).rotated(by: -rotation) + crop.center
    }

    public func mmPerPixel() throws(PhotoPartError) -> Double {
        switch scale {
        case nil:
            throw .missingScale
        case let .twoPoints(a, b, mm)?:
            guard mm.isFinite, mm > 0 else { throw .invalidDistance }
            let px = a.distance(to: b)
            guard px >= 10 else { throw .calibrationTooShort }
            return mm / px
        case let .width(mm)?:
            let w = outputSize().x
            guard mm.isFinite, mm > 0, w > 0 else { throw .invalidDistance }
            return mm / w
        }
    }

    @discardableResult
    public mutating func addPin(atOutput p: Vec2) -> String {
        let id = "connector\(nextPinNumber)"
        let name = "P\(nextPinNumber)"
        nextPinNumber += 1
        let position = toSource(snapped(p, excluding: nil))
        pins.append(DraftPin(id: id, name: name, position: position))
        return id
    }

    public mutating func movePin(_ id: String, toOutput p: Vec2) {
        guard let i = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[i].position = toSource(snapped(p, excluding: id))
    }

    public mutating func removePin(_ id: String) {
        pins.removeAll { $0.id == id }
        buses = buses.map { $0.filter { $0 != id } }.filter { $0.count >= 2 }
    }

    /// Snaps in output space relative to the first pin; no-op without a first pin, scale, or when moving the anchor.
    private func snapped(_ p: Vec2, excluding id: String?) -> Vec2 {
        guard gridSnap, let first = pins.first, first.id != id,
              let mm = try? mmPerPixel() else { return p }
        return snapToPinGrid(p, anchor: toOutput(first.position), mmPerPixel: mm)
    }
}
