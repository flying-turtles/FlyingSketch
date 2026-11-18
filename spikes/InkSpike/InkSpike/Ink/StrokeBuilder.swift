import CoreGraphics
import Foundation

struct InkSample {
    var location: CGPoint
    /// Normalized 0...1. Finger input reports 0; caller substitutes a default.
    var pressure: Double
    var time: TimeInterval
}

struct StrokePoint {
    var position: CGPoint
    var radius: CGFloat
}

struct StrokeParams {
    var baseWidth: Double
    var smoothingEnabled: Bool
    var minCutoff: Double
    var beta: Double
    var usePressure: Bool
    var pressureGamma: Double
}

/// Turns raw touch samples into smoothed, width-varying stroke points.
/// Value type so the filter state can be copied cheaply to run predicted
/// touches through it without disturbing committed state.
struct StrokeBuilder {
    let params: StrokeParams
    private(set) var committed: [StrokePoint] = []
    private var fx: OneEuroFilter
    private var fy: OneEuroFilter
    private var smoothedPressure: Double?

    init(params: StrokeParams) {
        self.params = params
        fx = OneEuroFilter(minCutoff: params.minCutoff, beta: params.beta)
        fy = OneEuroFilter(minCutoff: params.minCutoff, beta: params.beta)
    }

    mutating func add(_ sample: InkSample) {
        if let point = Self.process(sample, params: params, fx: &fx, fy: &fy, pressure: &smoothedPressure) {
            committed.append(point)
        }
    }

    /// Committed points plus predicted samples, run through a copy of the filter state.
    func points(predicted: [InkSample]) -> [StrokePoint] {
        guard !predicted.isEmpty else { return committed }
        var fx = fx, fy = fy, pressure = smoothedPressure
        var result = committed
        for sample in predicted {
            if let point = Self.process(sample, params: params, fx: &fx, fy: &fy, pressure: &pressure) {
                result.append(point)
            }
        }
        return result
    }

    private static func process(
        _ sample: InkSample,
        params: StrokeParams,
        fx: inout OneEuroFilter,
        fy: inout OneEuroFilter,
        pressure: inout Double?
    ) -> StrokePoint? {
        var x = Double(sample.location.x)
        var y = Double(sample.location.y)
        if params.smoothingEnabled {
            x = fx.filter(x, time: sample.time)
            y = fy.filter(y, time: sample.time)
        }

        let p = pressure.map { 0.6 * sample.pressure + 0.4 * $0 } ?? sample.pressure
        pressure = p

        let widthFactor: Double = params.usePressure ? 0.2 + 0.8 * pow(p, params.pressureGamma) : 0.6
        let radius = CGFloat(params.baseWidth * widthFactor / 2)
        return StrokePoint(position: CGPoint(x: x, y: y), radius: max(radius, 0.35))
    }
}
