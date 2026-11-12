// Copyright 2026 Niantic Spatial.

import MetalKit
import NSDK
import simd
import UIKit

/// Draws the VPS2 mesh during playback, where the postProcess render callback is unavailable
/// (RealityKit traps when one is installed on the nonAR playback view).
///
/// A transparent MTKView layered between the playback camera view and the NSDKView renders the
/// same `MeshRenderer` content, so view order gives the same layering as the live path: camera
/// behind the mesh, RealityKit markers and arrow on top.
final class VPS2PlaybackMeshView: MTKView, MTKViewDelegate {

    private let nsdkView: NSDKView
    private let meshRenderer: MeshRenderer
    private let commandQueue: MTLCommandQueue
    /// Returns the asset pose to render the mesh at, or nil while the mesh is hidden.
    private let worldTransform: () -> simd_float4x4?

    init(
        nsdkView: NSDKView,
        meshRenderer: MeshRenderer,
        device: MTLDevice,
        worldTransform: @escaping () -> simd_float4x4?
    ) {
        self.nsdkView = nsdkView
        self.meshRenderer = meshRenderer
        self.commandQueue = device.makeCommandQueue()!
        self.worldTransform = worldTransform
        super.init(frame: .zero, device: device)

        delegate = self
        isOpaque = false
        backgroundColor = .clear
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // Matches the sRGB textures MeshRenderer decodes, so textured chunks keep their colors.
        colorPixelFormat = .bgra8Unorm_srgb
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("VPS2PlaybackMeshView does not support init(coder:)")
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            drawableSize.width > 0,
            let drawable = currentDrawable,
            let clearPass = currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        // Clear to transparent every frame; the mesh composites over it with a load action.
        if let clearEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: clearPass) {
            clearEncoder.endEncoding()
        }

        if let worldTransform = worldTransform(), let camera = nsdkView.getCamera() {
            let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
            // Aspect-fill viewport so the mesh aligns with the playback camera image behind it.
            let viewportRect = camera.viewportRect(
                fittingIn: drawableSize,
                displayOrientation: orientation
            )
            let projection = camera.projectionMatrix(
                for: orientation,
                viewportSize: viewportRect.size,
                zNear: 0.01,
                zFar: 100.0
            )
            meshRenderer.encode(
                commandBuffer: commandBuffer,
                outputTexture: drawable.texture,
                viewMatrix: camera.viewMatrix(for: orientation),
                projectionMatrix: Self.reverseZ(projection),
                worldTransform: worldTransform,
                viewport: MTLViewport(
                    originX: viewportRect.origin.x,
                    originY: viewportRect.origin.y,
                    width: viewportRect.width,
                    height: viewportRect.height,
                    znear: 0,
                    zfar: 1
                )
            )
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The camera's projection maps clip depth forward (near 0, far 1) while MeshRenderer
    /// expects reverse-Z, so remap clip z to w - z.
    private static func reverseZ(_ projection: simd_float4x4) -> simd_float4x4 {
        let remap = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, -1, 0),
            SIMD4<Float>(0, 0, 1, 1)
        )
        return remap * projection
    }
}
