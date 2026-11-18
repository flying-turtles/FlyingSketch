import SketchCore

/// Turns raw samples into InkPoints. Value type so filter state can be copied
/// to run predicted samples without disturbing committed state.
public struct StrokeBuilder: Sendable {
    public let params: InkParams
    public private(set) var committed: [InkPoint] = []
    private var fx: OneEuroFilter
    private var fy: OneEuroFilter
    private var smoothedPressure: Double?
    private var startTime: Double?

    public init(params: InkParams) {
        self.params = params
        fx = OneEuroFilter(minCutoff: params.minCutoff, beta: params.beta)
        fy = OneEuroFilter(minCutoff: params.minCutoff, beta: params.beta)
    }

    public mutating func add(_ s: InkSample) {
        if startTime == nil { startTime = s.timestamp }
        committed.append(Self.process(s, start: startTime!, smoothing: params.smoothing,
                                      fx: &fx, fy: &fy, pressure: &smoothedPressure))
    }

    /// Committed points plus predicted samples, run through a copy of the filter state.
    public func points(predicted: [InkSample]) -> [InkPoint] {
        guard !predicted.isEmpty else { return committed }
        var fx = fx, fy = fy, pressure = smoothedPressure
        let start = startTime ?? predicted[0].timestamp
        var result = committed
        for s in predicted {
            result.append(Self.process(s, start: start, smoothing: params.smoothing,
                                       fx: &fx, fy: &fy, pressure: &pressure))
        }
        return result
    }

    private static func process(
        _ s: InkSample, start: Double, smoothing: Bool,
        fx: inout OneEuroFilter, fy: inout OneEuroFilter, pressure: inout Double?
    ) -> InkPoint {
        var pos = s.position
        var p = s.force.map { min(max($0, 0), 1) } ?? 0.5
        if smoothing {
            pos = Vec2(x: fx.filter(pos.x, time: s.timestamp), y: fy.filter(pos.y, time: s.timestamp))
            p = pressure.map { 0.6 * p + 0.4 * $0 } ?? p
            pressure = p
        }
        return InkPoint(position: pos, pressure: p, altitude: s.altitude, azimuth: s.azimuth,
                        time: s.timestamp - start)
    }
}
