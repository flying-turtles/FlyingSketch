/// Normal equations `H x = rhs` with `H` symmetric positive definite, stored dense (row-major, lower
/// triangle used). Solved by envelope (profile) Cholesky: each row only works from its first non-zero
/// column on, so banded systems (chains of bodies) cost O(n · band²) while general ones stay dense.
struct NormalEquations: Sendable {
    let n: Int
    private(set) var h: [Double]
    private(set) var rhs: [Double]
    /// Envelope: first column of each row that was ever written.
    private var first: [Int]

    init(size: Int) {
        n = size
        h = Array(repeating: 0, count: size * size)
        rhs = Array(repeating: 0, count: size)
        first = Array(0..<size)
    }

    /// Adds `value` to `H[i][j]` for `i >= j` (callers add every lower-triangle entry exactly once).
    mutating func addLower(_ i: Int, _ j: Int, _ value: Double) {
        h[i * n + j] += value
        if j < first[i] { first[i] = j }
    }

    mutating func addRHS(_ i: Int, _ value: Double) {
        rhs[i] += value
    }

    /// Solution of `H x = rhs`, or nil when `H` is not numerically positive definite.
    func solve() -> [Double]? {
        var l = h
        var x = rhs
        let ok = l.withUnsafeMutableBufferPointer { l in
            first.withUnsafeBufferPointer { first in
                x.withUnsafeMutableBufferPointer { x in
                    Self.factorAndSolve(l, first, x, n)
                }
            }
        }
        return ok ? x : nil
    }

    private static func factorAndSolve(_ l: UnsafeMutableBufferPointer<Double>, _ first: UnsafeBufferPointer<Int>,
                                       _ x: UnsafeMutableBufferPointer<Double>, _ n: Int) -> Bool {
        // L Lᵀ = H in place; fill-in stays inside each row's envelope.
        for i in 0..<n {
            let ri = i * n
            for j in first[i]...i {
                let rj = j * n
                var sum = l[ri + j]
                var k = max(first[i], first[j])
                while k < j {
                    sum -= l[ri + k] * l[rj + k]
                    k += 1
                }
                if j < i {
                    l[ri + j] = sum / l[rj + j]
                } else {
                    guard sum > 0, sum.isFinite else { return false }
                    l[ri + i] = sum.squareRoot()
                }
            }
        }
        // L y = rhs.
        for i in 0..<n {
            let ri = i * n
            var sum = x[i]
            var k = first[i]
            while k < i {
                sum -= l[ri + k] * x[k]
                k += 1
            }
            x[i] = sum / l[ri + i]
        }
        // Lᵀ x = y, column-oriented so only envelope entries are read.
        var i = n - 1
        while i >= 0 {
            let ri = i * n
            x[i] /= l[ri + i]
            let xi = x[i]
            var k = first[i]
            while k < i {
                x[k] -= l[ri + k] * xi
                k += 1
            }
            i -= 1
        }
        for i in 0..<n where !x[i].isFinite { return false }
        return true
    }
}
