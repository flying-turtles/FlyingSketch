/// Lower-triangle row envelope (profile) of a symmetric matrix: row `i` holds columns `first[i]...i`, stored
/// contiguously from `offset[i]`.
struct Envelope: Sendable {
    let first: [Int]
    let offset: [Int]
    var n: Int { first.count }
    var count: Int { offset[first.count] }

    /// `first[i] <= i` per row.
    init(first: [Int]) {
        self.first = first
        var offset = [Int](repeating: 0, count: first.count + 1)
        for i in first.indices { offset[i + 1] = offset[i] + i - first[i] + 1 }
        self.offset = offset
    }
}

/// Normal equations `H x = rhs` with `H` symmetric positive definite, stored as the lower triangle inside a
/// fixed envelope. Solved by envelope (profile) Cholesky: fill-in stays inside each row's envelope, so banded
/// systems (chains of bodies) cost O(n · band²) in time and O(n · band) in memory, while general ones stay dense.
struct NormalEquations: Sendable {
    let envelope: Envelope
    private(set) var h: [Double]
    private(set) var rhs: [Double]

    var n: Int { envelope.n }

    init(envelope: Envelope) {
        self.envelope = envelope
        h = Array(repeating: 0, count: envelope.count)
        rhs = Array(repeating: 0, count: envelope.n)
    }

    /// Adds `value` to `H[i][j]` for `envelope.first[i] <= j <= i` (callers add every lower-triangle entry
    /// exactly once).
    mutating func addLower(_ i: Int, _ j: Int, _ value: Double) {
        let first = envelope.first[i]
        precondition(j >= first && j <= i, "entry (\(i), \(j)) outside the envelope")
        h[envelope.offset[i] + j - first] += value
    }

    mutating func addRHS(_ i: Int, _ value: Double) {
        rhs[i] += value
    }

    /// Solution of `H x = rhs`, or nil when `H` is not numerically positive definite.
    func solve() -> [Double]? {
        var l = h
        var x = rhs
        let n = self.n
        let ok = l.withUnsafeMutableBufferPointer { l in
            envelope.first.withUnsafeBufferPointer { first in
                envelope.offset.withUnsafeBufferPointer { offset in
                    x.withUnsafeMutableBufferPointer { x in
                        Self.factorAndSolve(l, first, offset, x, n)
                    }
                }
            }
        }
        return ok ? x : nil
    }

    private static func factorAndSolve(_ l: UnsafeMutableBufferPointer<Double>, _ first: UnsafeBufferPointer<Int>,
                                       _ offset: UnsafeBufferPointer<Int>, _ x: UnsafeMutableBufferPointer<Double>,
                                       _ n: Int) -> Bool {
        // L Lᵀ = H in place; `base[i] + k` is entry (i, k).
        @inline(__always) func base(_ i: Int) -> Int { offset[i] - first[i] }
        for i in 0..<n {
            let bi = base(i)
            for j in first[i]...i {
                let bj = base(j)
                var sum = l[bi + j]
                var k = max(first[i], first[j])
                while k < j {
                    sum -= l[bi + k] * l[bj + k]
                    k += 1
                }
                if j < i {
                    l[bi + j] = sum / l[bj + j]
                } else {
                    guard sum > 0, sum.isFinite else { return false }
                    l[bi + i] = sum.squareRoot()
                }
            }
        }
        // L y = rhs.
        for i in 0..<n {
            let bi = base(i)
            var sum = x[i]
            var k = first[i]
            while k < i {
                sum -= l[bi + k] * x[k]
                k += 1
            }
            x[i] = sum / l[bi + i]
        }
        // Lᵀ x = y, column-oriented so only envelope entries are read.
        var i = n - 1
        while i >= 0 {
            let bi = base(i)
            x[i] /= l[bi + i]
            let xi = x[i]
            var k = first[i]
            while k < i {
                x[k] -= l[bi + k] * xi
                k += 1
            }
            i -= 1
        }
        for i in 0..<n where !x[i].isFinite { return false }
        return true
    }
}
