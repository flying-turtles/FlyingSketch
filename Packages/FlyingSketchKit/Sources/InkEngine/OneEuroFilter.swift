import Foundation

/// One-Euro filter (Casiez et al. 2012): adaptive low-pass that smooths jitter
/// at low speed and cuts lag at high speed.
struct OneEuroFilter: Sendable {
    var minCutoff: Double
    var beta: Double
    var derivativeCutoff: Double = 1.0

    private var lastValue: Double?
    private var lastRaw: Double?
    private var lastDerivative: Double = 0
    private var lastTime: Double?

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    mutating func filter(_ value: Double, time: Double) -> Double {
        guard let lastTime, let lastRaw, let lastValue else {
            self.lastTime = time
            self.lastRaw = value
            self.lastValue = value
            return value
        }
        let dt = max(time - lastTime, 1e-4)
        let rawDerivative = (value - lastRaw) / dt
        let dAlpha = Self.alpha(cutoff: derivativeCutoff, dt: dt)
        let derivative = dAlpha * rawDerivative + (1 - dAlpha) * lastDerivative
        let cutoff = minCutoff + beta * abs(derivative)
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let filtered = a * value + (1 - a) * lastValue

        self.lastTime = time
        self.lastRaw = value
        self.lastValue = filtered
        self.lastDerivative = derivative
        return filtered
    }
}
