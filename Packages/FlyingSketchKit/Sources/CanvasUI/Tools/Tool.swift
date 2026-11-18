import SketchCore
import InkEngine

public enum ToolKind: Equatable {
    case ink(InkTool), eraser, lasso, shape(ShapeKind), text, image
}

public struct ToolState {
    public var kind: ToolKind
    public var color: RGBAColor
    /// Millimetres (world units, independent of zoom).
    public var inkWidth: Double
    public var params: InkParams
    /// When true, only the Pencil inks; finger touches are left to other tools.
    public var pencilOnly: Bool

    public init(kind: ToolKind = .ink(.pen), color: RGBAColor = .black, inkWidth: Double = 0.5,
                params: InkParams = InkParams(), pencilOnly: Bool = true) {
        self.kind = kind
        self.color = color
        self.inkWidth = inkWidth
        self.params = params
        self.pencilOnly = pencilOnly
    }
}
