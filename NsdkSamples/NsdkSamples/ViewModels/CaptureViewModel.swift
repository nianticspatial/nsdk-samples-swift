// Copyright 2026 Niantic Spatial.

import Foundation
import Metal
import NSDK
import Combine

/// Transforms raw raycast buffer data from an NSDKScanningSession into a display-ready composited texture.
///
/// Subscribes to:
/// - `session.$latestRaycastBuffer` for per-frame raycast images
///
/// Publishes:
/// - `compositeTexture`: `MTLTexture?` — raycast image composited with red stripes marking unscanned areas. Initially `nil`. Updated each frame while scanning.
final class CaptureViewModel {

    // MARK: - Published State

    @Published private(set) var compositeTexture: MTLTexture?

    // MARK: - Stripe Parameters

    var stripeStride: UInt32 = 7
    var stripeRedPixels: UInt32 = 5

    // MARK: - Private Metal Resources

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let compositeKernel: MTLComputePipelineState?
    private var rgbaTexture: MTLTexture?
    private var cachedOutput: MTLTexture?
    private var cachedOutputWidth: Int = 0
    private var cachedOutputHeight: Int = 0
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(session: NSDKScanningSession) {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()

        if let device,
           let library = device.makeDefaultLibrary(),
           let kernelFunction = library.makeFunction(name: "scanning_composite_kernel") {
            compositeKernel = try? device.makeComputePipelineState(function: kernelFunction)
        } else {
            compositeKernel = nil
        }

        // Subscribe to raycast buffer updates
        session.$latestRaycastBuffer
            .sink { [weak self] buffer in
                guard let self, let buffer else { return }
                self.update(from: buffer)
            }
            .store(in: &cancellables)
    }

    // MARK: - Private

    private func update(from buffer: RaycastBuffer) {
        guard let device else { return }
        TextureUtils.createOrUpdateTexture(from: buffer.rgba, texture: &rgbaTexture, device: device)
        guard let source = rgbaTexture else { return }
        composite(from: source)
    }

    private func composite(from source: MTLTexture) {
        guard let device,
              let kernel = compositeKernel,
              let queue = commandQueue,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        let width = source.width
        let height = source.height

        if cachedOutput == nil || cachedOutputWidth != width || cachedOutputHeight != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .shared
            cachedOutput = device.makeTexture(descriptor: descriptor)
            cachedOutputWidth = width
            cachedOutputHeight = height
        }

        guard let output = cachedOutput else { return }

        struct CompositeUniforms {
            var stripeStride: UInt32
            var stripeRedPixels: UInt32
        }
        var uniforms = CompositeUniforms(stripeStride: stripeStride, stripeRedPixels: stripeRedPixels)

        encoder.setComputePipelineState(kernel)
        encoder.setTexture(output, index: 0)
        encoder.setTexture(source, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)

        let threadgroupWidth = min(kernel.threadExecutionWidth, width)
        let threadgroupHeight = min(kernel.maxTotalThreadsPerThreadgroup / threadgroupWidth, height)
        let threadgroupSize = MTLSize(width: threadgroupWidth, height: threadgroupHeight, depth: 1)
        let threadgroupCount = MTLSize(
            width: (width + threadgroupWidth - 1) / threadgroupWidth,
            height: (height + threadgroupHeight - 1) / threadgroupHeight,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        compositeTexture = cachedOutput
    }
}
