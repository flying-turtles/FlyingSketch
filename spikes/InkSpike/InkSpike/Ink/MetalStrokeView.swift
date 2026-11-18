import Metal
import QuartzCore
import UIKit

/// Transparent overlay that renders only the live stroke, synchronously on each touch event.
final class MetalStrokeView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var msaaTexture: MTLTexture?
    private let sampleCount = 4

    override init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: strokeShaderSource, options: nil)
        else { fatalError("Metal unavailable") }
        self.device = device
        self.queue = queue

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "stroke_vertex")
        desc.fragmentFunction = library.makeFunction(name: "stroke_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.rasterSampleCount = sampleCount
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("Pipeline: \(error)")
        }
        super.init(frame: frame)

        isOpaque = false
        backgroundColor = .clear
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.presentsWithTransaction = false
        metalLayer.maximumDrawableCount = 3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            msaaTexture = nil
        }
    }

    func render(triangles: [SIMD2<Float>]) {
        guard bounds.width > 0, let drawable = metalLayer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer()
        else { return }

        let target = drawable.texture
        if msaaTexture == nil || msaaTexture?.width != target.width || msaaTexture?.height != target.height {
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: target.width, height: target.height, mipmapped: false)
            td.textureType = .type2DMultisample
            td.sampleCount = sampleCount
            td.usage = .renderTarget
            td.storageMode = .memoryless
            msaaTexture = device.makeTexture(descriptor: td)
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaaTexture
        pass.colorAttachments[0].resolveTexture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if !triangles.isEmpty,
           let buffer = device.makeBuffer(bytes: triangles,
                                          length: MemoryLayout<SIMD2<Float>>.stride * triangles.count) {
            var viewSize = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
            var color = SIMD4<Float>(0, 0, 0, 1)
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// Compiled at runtime so the build needs no Metal toolchain.
private let strokeShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
};

// Input positions are in view points (origin top-left, y down).
vertex VertexOut stroke_vertex(uint vid [[vertex_id]],
                               const device float2 *positions [[buffer(0)]],
                               constant float2 &viewSize [[buffer(1)]]) {
    float2 p = positions[vid];
    float2 ndc = float2(p.x / viewSize.x * 2.0 - 1.0, 1.0 - p.y / viewSize.y * 2.0);
    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    return out;
}

fragment float4 stroke_fragment(constant float4 &color [[buffer(0)]]) {
    return color;
}
"""
