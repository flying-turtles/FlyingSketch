import CoreGraphics
import CoreVideo
import Foundation
import SketchCore
import Vision

public protocol CutoutProviding: Sendable {
    func instances(in image: SourceImage) async throws(PhotoPartError) -> [MaskBitmap]
}

/// Vision foreground-instance cutout. Masks are at source image resolution.
public struct VisionCutout: CutoutProviding {
    public init() {}

    /// Runs off the main actor (nonisolated async). Largest instance first.
    public nonisolated func instances(in image: SourceImage) async throws(PhotoPartError) -> [MaskBitmap] {
        let masks: [MaskBitmap]
        do {
            masks = try Self.runVision(on: image.image)
        } catch {
            throw .cutoutUnavailable
        }
        guard !masks.isEmpty else { throw .noForeground }
        return masks
    }

    private static func runVision(on image: CGImage) throws -> [MaskBitmap] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first else { return [] }
        var result: [(mask: MaskBitmap, area: Int)] = []
        for i in observation.allInstances {
            let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: i), from: handler)
            guard CVPixelBufferGetWidth(buffer) == image.width, CVPixelBufferGetHeight(buffer) == image.height else {
                throw PhotoPartError.cutoutUnavailable
            }
            let mask = mask(from: buffer)
            let area = mask.bytes.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
            if area > 0 { result.append((mask, area)) }
        }
        return result.sorted { $0.area > $1.area }.map(\.mask)
    }

    /// Thresholds a one-component buffer: float >= 0.5, byte >= 128.
    /// Other pixel formats yield an empty mask of the buffer's size.
    static func mask(from buffer: CVPixelBuffer) -> MaskBitmap {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        var mask = MaskBitmap(width: w, height: h, filled: false)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_OneComponent8
        else { return mask }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return mask }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<h {
            let row = base + y * bpr
            if format == kCVPixelFormatType_OneComponent32Float {
                let p = row.assumingMemoryBound(to: Float.self)
                for x in 0..<w where p[x] >= 0.5 { mask.bytes[y * w + x] = 255 }
            } else {
                let p = row.assumingMemoryBound(to: UInt8.self)
                for x in 0..<w where p[x] >= 128 { mask.bytes[y * w + x] = 255 }
            }
        }
        return mask
    }
}

/// Index of the first mask containing `point`.
public func instanceIndex(at point: Vec2, in masks: [MaskBitmap]) -> Int? {
    masks.firstIndex { $0.value(at: point) }
}
