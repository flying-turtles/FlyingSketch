import SketchCore

/// Raw input sample. Position in millimetres.
public struct InkSample: Sendable {
    public var position: Vec2
    /// Normalized 0...1; nil = finger (no force).
    public var force: Double?
    public var altitude: Double?
    public var azimuth: Double?
    public var timestamp: Double

    public init(position: Vec2, force: Double? = nil, altitude: Double? = nil, azimuth: Double? = nil, timestamp: Double) {
        self.position = position
        self.force = force
        self.altitude = altitude
        self.azimuth = azimuth
        self.timestamp = timestamp
    }
}

public struct InkParams: Sendable {
    public var smoothing: Bool
    public var minCutoff: Double
    public var beta: Double
    public var pressureGamma: Double

    public init(smoothing: Bool = false, minCutoff: Double = 2.0, beta: Double = 0.05, pressureGamma: Double = 1.0) {
        self.smoothing = smoothing
        self.minCutoff = minCutoff
        self.beta = beta
        self.pressureGamma = pressureGamma
    }
}
