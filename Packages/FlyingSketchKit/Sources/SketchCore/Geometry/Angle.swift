import Foundation

/// Wraps `a` to [0, 2π); an angle within 1e-9 of k·π/2 snaps to exactly k·π/2 (2π -> 0). Non-finite stays non-finite.
public func normalizedAngle(_ a: Double) -> Double {
    let full = 2 * Double.pi
    var r = a.truncatingRemainder(dividingBy: full)
    if r < 0 { r += full }
    let k = (r / (.pi / 2)).rounded()
    if abs(r - k * .pi / 2) < 1e-9 { r = k * .pi / 2 }
    return r >= full ? 0 : r
}

/// 0...3 when `normalizedAngle(a)` is an exact quarter turn, else nil.
public func quarterTurns(of a: Double) -> Int? {
    let n = normalizedAngle(a)
    guard n.isFinite else { return nil }
    let k = Int((n / (.pi / 2)).rounded())
    return n == Double(k) * .pi / 2 ? k % 4 : nil
}
