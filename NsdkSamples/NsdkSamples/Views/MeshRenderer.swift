// Copyright 2026 Niantic Spatial.

import Metal
import MetalKit
import NSDK
import simd

/// Draws mesh chunks with Metal on top of an already-rendered AR frame, for use from
/// `ARView.renderCallbacks.postProcess`.
///
/// A chunk renders textured when it carries a decodable texture and texture coordinates, and
/// as a see-through wireframe otherwise. The wireframe self-occludes: a depth-only prepass
/// writes the solid mesh into a private depth buffer and the wireframe pass depth-tests
/// against it. The mesh composites over the finished frame, so it never occludes RealityKit
/// content; passing the scene depth to `encode(...)` makes RealityKit content draw over the
/// mesh as well.
///
/// Chunks are managed from the main thread; `encode(...)` runs on the render thread. The class is
/// `nonisolated` so that `encode(...)` stays off the main actor even in a module whose default
/// actor isolation is `MainActor`. It is `@unchecked Sendable`: `chunksLock` guards the chunks the
/// two threads share, and only `encode(...)` touches the pipeline and depth texture caches.
nonisolated final class MeshRenderer: @unchecked Sendable {

    private struct Uniforms {
        var modelView: simd_float4x4
        var projection: simd_float4x4
    }

    /// Holds only Metal resources, which may be retained from any thread, so a command buffer's
    /// completion handler can keep a copy alive.
    private struct RenderableChunk: @unchecked Sendable {
        let positionBuffer: MTLBuffer
        let indexBuffer: MTLBuffer
        let indexCount: Int
        let uvBuffer: MTLBuffer?
        let texture: MTLTexture?
        let transform: simd_float4x4
        var isHidden = false

        var isTextured: Bool { texture != nil && uvBuffer != nil }
    }

    /// Pipelines are built against the output texture's pixel format on first use.
    private struct Pipelines {
        let colorPixelFormat: MTLPixelFormat
        let textured: MTLRenderPipelineState
        let depthPrepass: MTLRenderPipelineState
        let wireframe: MTLRenderPipelineState

        /// True on GPUs without barycentric support, where the wireframe pipeline
        /// expects a `.lines` triangle fill mode instead of interior discards.
        let wireframeUsesLinesFillMode: Bool
    }

    private let device: MTLDevice
    private let library: MTLLibrary
    private let textureLoader: MTKTextureLoader

    /// Bound in place of the scene depth when none is provided; the mask flag keeps it unread.
    private let dummySceneDepthTexture: MTLTexture

    private var pipelines: Pipelines?

    /// The color format pipeline creation last failed for, so it is not retried every frame.
    private var pipelineFailedFormat: MTLPixelFormat?
    private var depthTexture: MTLTexture?

    /// Writes with `.greater`: the projection is reverse-Z, so nearer fragments carry larger
    /// depth. Used by the prepass and the textured chunks.
    private let depthWriteState: MTLDepthStencilState

    /// Tests with `.greaterEqual`, writes off. The wireframe rasterizes the same triangles as
    /// the prepass, so its visible edges land on equal depth and pass.
    private let depthTestOnlyState: MTLDepthStencilState

    /// Protects `chunks`: the main thread mutates, the render thread reads.
    private let chunksLock = NSLock()
    private var chunks: [Int64: RenderableChunk] = [:]

    // MARK: - Initialization

    init(device: MTLDevice) {
        self.device = device
        self.library = device.makeDefaultLibrary()!
        self.textureLoader = MTKTextureLoader(device: device)

        let dummyDepthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: 1,
            height: 1,
            mipmapped: false
        )
        dummyDepthDescriptor.usage = .shaderRead
        dummyDepthDescriptor.storageMode = .private
        dummySceneDepthTexture = device.makeTexture(descriptor: dummyDepthDescriptor)!

        let writeDesc = MTLDepthStencilDescriptor()
        writeDesc.depthCompareFunction = .greater
        writeDesc.isDepthWriteEnabled = true
        depthWriteState = device.makeDepthStencilState(descriptor: writeDesc)!

        let testDesc = MTLDepthStencilDescriptor()
        testDesc.depthCompareFunction = .greaterEqual
        testDesc.isDepthWriteEnabled = false
        depthTestOnlyState = device.makeDepthStencilState(descriptor: testDesc)!
    }

    // MARK: - Chunk management (main thread)

    /// Inserts or replaces one chunk. Pass the encoded texture image bytes (e.g. JPEG or PNG)
    /// in `textureData`; a `nil`, empty, or undecodable value renders the chunk as wireframe.
    /// `transform` positions the chunk in ARKit world space; pass identity for chunks whose
    /// vertices are already world space. A chunk added with `hidden` is never drawn until
    /// revealed with `setChunkHidden(false, id:)`.
    func setChunk(
        id: Int64,
        meshData: MeshData,
        textureData: Data?,
        transform: simd_float4x4,
        hidden: Bool = false
    ) {
        let vertexCount = meshData.verticesPtr.count / 3
        guard
            vertexCount > 0,
            !meshData.indicesPtr.isEmpty,
            let verticesBase = meshData.verticesPtr.baseAddress,
            let indicesBase = meshData.indicesPtr.baseAddress,
            let positionBuffer = device.makeBuffer(
                bytes: verticesBase,
                length: meshData.verticesPtr.count * MemoryLayout<Float>.stride
            ),
            let indexBuffer = device.makeBuffer(
                bytes: indicesBase,
                length: meshData.indicesPtr.count * MemoryLayout<UInt32>.stride
            )
        else { return }

        var uvBuffer: MTLBuffer?
        if let uvsPtr = meshData.uvsPtr,
           uvsPtr.count == vertexCount * 2,
           let uvsBase = uvsPtr.baseAddress {
            uvBuffer = device.makeBuffer(
                bytes: uvsBase,
                length: uvsPtr.count * MemoryLayout<Float>.stride
            )
        }

        // A texture is only usable with texture coordinates, so skip decoding without them.
        var texture: MTLTexture?
        if uvBuffer != nil, let textureData, !textureData.isEmpty {
            texture = try? textureLoader.newTexture(data: textureData, options: [.SRGB: true])
        }

        let chunk = RenderableChunk(
            positionBuffer: positionBuffer,
            indexBuffer: indexBuffer,
            indexCount: meshData.indicesPtr.count,
            uvBuffer: uvBuffer,
            texture: texture,
            transform: transform,
            isHidden: hidden
        )
        chunksLock.lock()
        chunks[id] = chunk
        chunksLock.unlock()
    }

    /// Hides or reveals a chunk without dropping its buffers or decoded texture.
    func setChunkHidden(_ hidden: Bool, id: Int64) {
        chunksLock.lock()
        chunks[id]?.isHidden = hidden
        chunksLock.unlock()
    }

    func removeChunk(id: Int64) {
        chunksLock.lock()
        chunks.removeValue(forKey: id)
        chunksLock.unlock()
    }

    func removeAllChunks() {
        chunksLock.lock()
        chunks.removeAll()
        chunksLock.unlock()
    }

    // MARK: - Rendering (render thread)

    /// Encodes the mesh into `commandBuffer` (does not commit), compositing over
    /// `outputTexture` with `loadAction: .load`.
    ///
    /// `viewMatrix` is the ARKit-convention camera view matrix. `projectionMatrix` must be a
    /// reverse-Z projection, as `PostProcessContext.projection` provides. `worldTransform` is
    /// applied to every chunk (e.g. the localized asset anchor's transform). When
    /// `sceneDepthTexture` is provided (e.g. `PostProcessContext.sourceDepthTexture`), the
    /// mesh is discarded on every pixel that scene content covers, so it draws behind the
    /// scene's own entities. `viewport` overrides the full-target default, e.g. for an
    /// aspect-fill playback viewport.
    func encode(
        commandBuffer: MTLCommandBuffer,
        outputTexture: MTLTexture,
        sceneDepthTexture: MTLTexture? = nil,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        worldTransform: simd_float4x4 = matrix_identity_float4x4,
        viewport: MTLViewport? = nil
    ) {
        chunksLock.lock()
        let visibleChunks = chunks.values.filter { !$0.isHidden }
        chunksLock.unlock()

        guard
            !visibleChunks.isEmpty,
            let pipelines = pipelines(for: outputTexture.pixelFormat),
            let depthTexture = depthTexture(width: outputTexture.width, height: outputTexture.height)
        else { return }

        // Keep the chunks' buffers and textures alive until the GPU is done with them, even if
        // they are removed meanwhile. The caller's command buffer may not retain its resources.
        commandBuffer.addCompletedHandler { _ in _ = visibleChunks }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = outputTexture
        renderPass.colorAttachments[0].loadAction = .load
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.depthAttachment.texture = depthTexture
        renderPass.depthAttachment.loadAction = .clear
        renderPass.depthAttachment.storeAction = .dontCare

        // 0 is the far plane in reverse-Z.
        renderPass.depthAttachment.clearDepth = 0.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }

        // Scanned meshes are viewed from both sides, so leave culling off.
        encoder.setCullMode(.none)
        if let viewport {
            encoder.setViewport(viewport)
        }

        // Fragment bindings persist across pipeline switches, so the scene depth mask is
        // set once for every draw below.
        var sceneDepthMask: UInt32 = sceneDepthTexture != nil ? 1 : 0
        encoder.setFragmentTexture(sceneDepthTexture ?? dummySceneDepthTexture, index: 1)
        encoder.setFragmentBytes(&sceneDepthMask, length: MemoryLayout<UInt32>.stride, index: 0)

        let viewWorld = viewMatrix * worldTransform
        let textured = visibleChunks.filter { $0.isTextured }
        let wireframe = visibleChunks.filter { !$0.isTextured }

        func draw(_ chunk: RenderableChunk) {
            var uniforms = Uniforms(
                modelView: viewWorld * chunk.transform,
                projection: projectionMatrix
            )
            encoder.setVertexBuffer(chunk.positionBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: chunk.indexCount,
                indexType: .uint32,
                indexBuffer: chunk.indexBuffer,
                indexBufferOffset: 0
            )
        }

        // Depth prepass: the wireframe chunks' solid faces.
        encoder.setDepthStencilState(depthWriteState)
        encoder.setRenderPipelineState(pipelines.depthPrepass)
        for chunk in wireframe {
            draw(chunk)
        }

        // Textured chunks also test against the prepass depth, so the mesh's textured and
        // wireframe parts occlude each other.
        encoder.setRenderPipelineState(pipelines.textured)
        for chunk in textured {
            encoder.setVertexBuffer(chunk.uvBuffer, offset: 0, index: 1)
            encoder.setFragmentTexture(chunk.texture, index: 0)
            draw(chunk)
        }

        // Wireframe edges: depth-tested against the prepass without writing, so lines
        // behind the mesh's own faces are discarded.
        encoder.setDepthStencilState(depthTestOnlyState)
        encoder.setRenderPipelineState(pipelines.wireframe)
        if pipelines.wireframeUsesLinesFillMode {
            encoder.setTriangleFillMode(.lines)

            // Rasterized lines land at slightly different depths than the prepass triangles,
            // so nudge them toward the camera (larger depth in reverse-Z) or about half their
            // pixels fail the depth test and the lines look dashed.
            encoder.setDepthBias(0, slopeScale: 1, clamp: 0)
        }
        for chunk in wireframe {
            draw(chunk)
        }

        encoder.endEncoding()
    }

    // MARK: - Lazy Metal state

    private func pipelines(for colorPixelFormat: MTLPixelFormat) -> Pipelines? {
        if let pipelines, pipelines.colorPixelFormat == colorPixelFormat {
            return pipelines
        }

        // Don't retry (and re-log) every frame after a failure for this format.
        if pipelineFailedFormat == colorPixelFormat {
            return nil
        }

        func makePipeline(
            vertex: String,
            fragment: String,
            blended: Bool,
            writesColor: Bool = true
        ) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            descriptor.depthAttachmentPixelFormat = .depth32Float
            if !writesColor {
                descriptor.colorAttachments[0].writeMask = []
            }
            if blended {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha

                // `.one` keeps the output premultiplied (color never exceeds alpha), which the
                // transparent playback view needs to composite correctly over the camera view.
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        let barycentricSupported = device.supportsShaderBarycentricCoordinates
        do {
            let built = Pipelines(
                colorPixelFormat: colorPixelFormat,
                textured: try makePipeline(
                    vertex: "meshRendererTexturedVertex",
                    fragment: "meshRendererTexturedFragment",
                    blended: false
                ),
                depthPrepass: try makePipeline(
                    vertex: "meshRendererWireframeVertex",
                    fragment: "meshRendererDepthOnlyFragment",
                    blended: false,
                    writesColor: false
                ),
                wireframe: try makePipeline(
                    vertex: "meshRendererWireframeVertex",
                    fragment: barycentricSupported
                        ? "meshRendererWireframeFragment"
                        : "meshRendererWireframeLineFragment",
                    blended: true
                ),
                wireframeUsesLinesFillMode: !barycentricSupported
            )
            pipelines = built
            print(
                "[MeshRenderer] Wireframe path: "
                    + (barycentricSupported ? "barycentric shader" : "lines fill mode fallback")
            )
            return built
        } catch {
            pipelineFailedFormat = colorPixelFormat
            print("[MeshRenderer] Unable to create pipelines: \(error)")
            return nil
        }
    }

    private func depthTexture(width: Int, height: Int) -> MTLTexture? {
        if let depthTexture, depthTexture.width == width, depthTexture.height == height {
            return depthTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        depthTexture = device.makeTexture(descriptor: descriptor)
        return depthTexture
    }
}
