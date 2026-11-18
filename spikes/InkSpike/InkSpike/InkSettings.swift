import Foundation
import Observation

/// Shared tuning knobs. All three panes read these, so the comparison is fair.
@Observable
final class InkSettings {
    var baseWidth: Double = 4
    var smoothingEnabled = true
    /// One-Euro filter: lower = smoother at slow speed (but more lag).
    var minCutoff: Double = 2.0
    /// One-Euro filter: higher = less lag at fast speed.
    var beta: Double = 0.05
    var usePrediction = true
    var usePressure = true
    /// Pressure curve exponent. <1 = soft, >1 = firm.
    var pressureGamma: Double = 1.0
    var pencilOnly = false
    var clearToken = 0

    /// Average input-to-GPU-submit latency per pane, in ms.
    var latencyMs: [String: Double] = [:]

    var strokeParams: StrokeParams {
        StrokeParams(
            baseWidth: baseWidth,
            smoothingEnabled: smoothingEnabled,
            minCutoff: minCutoff,
            beta: beta,
            usePressure: usePressure,
            pressureGamma: pressureGamma
        )
    }
}
