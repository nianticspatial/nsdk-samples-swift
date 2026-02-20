//
//  OcclusionViewController.swift
//
//  This sample reconstructs a transparent mesh directly from the depth texture.
//  The mesh can be used to occlude other objects, like the cube in the scene.
//

import UIKit
import ARKit
import Metal
import MetalKit
import simd
import SwiftyNsdk

final class OcclusionViewController: BaseARViewController {

    // MARK: - Metal Rendering

    private var mtlView: MTKView!
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!

    private var occlusionPipeline: MTLRenderPipelineState!
    private var cubePipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!

    private var occVertexBuffer: MTLBuffer!
    private var occIndexBuffer: MTLBuffer!
    private var occIndexCount: Int = 0
    private var didCreateOcclusionMesh = false

    private var cubeVertexBuffer: MTLBuffer!
    private var cubeIndexBuffer: MTLBuffer!
    private var cubeIndexCount: Int = 0

    // MARK: - Depth Data

    private var depthManager: DepthManager?
    private var depthTexture: MTLTexture?
    private var lastDepthFrameId: UInt64 = 0

    private var viewMatrix = matrix_identity_float4x4
    private var projectionMatrix = matrix_identity_float4x4
    private var intrinsicsMatrix = matrix_identity_float3x3
    private var extrinsicsMatrix = matrix_identity_float4x4

    struct OcclusionMeshUniforms {
        var viewProj: simd_float4x4
        var intrinsics: simd_float3x3
        var extrinsics: simd_float4x4
        var resolution: simd_float2
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        self.title = "Occlusion"
        helpLabel.text = "This sample reconstructs a transparent mesh directly from the depth texture.\n\nThis mesh is used to occlude CG content in the scene."

        setupDepthManager()
        setupMetalView()
        setupPipelines()
        setupCube()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        depthManager?.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        depthManager?.stop()
    }


    // MARK: - Setup

    private func setupMetalView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal device unavailable.")
        }

        self.device = device
        self.commandQueue = device.makeCommandQueue()

        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.isOpaque = false
        mtkView.backgroundColor = .clear
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.preferredFramesPerSecond = 60
        mtkView.delegate = self

        view.addSubview(mtkView)
        mtkView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            mtkView.topAnchor.constraint(equalTo: arView.topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: arView.bottomAnchor),
            mtkView.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: arView.trailingAnchor)
        ])

        self.mtlView = mtkView
    }

    private func setupDepthManager() {
        guard let session = nsdkManager?.session else {
            assertionFailure("NSDK session missing.")
            return
        }
        depthManager = DepthManager(nsdk: session)
    }

    // MARK: - Depth Fetching & Synchronization

    @discardableResult
    private func fetchDepthData() -> Bool {

        guard let device,
              let depthManager,
              let depthResult = depthManager.latestDepth(),
              let frame = arView.session.currentFrame
        else { return false }

        // Update depth frame and dependent matrices only when a new depth frame arrives
        if depthResult.frameId != lastDepthFrameId {
            lastDepthFrameId = depthResult.frameId

            let didUpdate = TextureUtils.createOrUpdateTexture(
                from: depthResult.image,
                texture: &depthTexture,
                device: device
            )

            if didUpdate {
                intrinsicsMatrix = depthResult.intrinsics
                extrinsicsMatrix = depthResult.pose
            }
        }

        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait

        // Always update ARKit camera matrices
        viewMatrix = frame.camera.viewMatrix(for: orientation)
        projectionMatrix = frame.camera.projectionMatrix(
            for: orientation,
            viewportSize: mtlView.drawableSize,
            zNear: 0.01,
            zFar: 10.0
        )

        return true
    }

    // MARK: - Pipeline Setup

    private func setupPipelines() {
        let library = try! device.makeDefaultLibrary(bundle: .main)

        // Occlusion mesh
        let occDesc = MTLRenderPipelineDescriptor()
        occDesc.vertexFunction = library.makeFunction(name: "occlusionMeshVertex")
        occDesc.fragmentFunction = library.makeFunction(name: "occlusionMeshFragment")
        occDesc.colorAttachments[0].pixelFormat = mtlView.colorPixelFormat
        occDesc.colorAttachments[0].writeMask = [/* .all */]  // depth-only, uncomment for debug
        occDesc.depthAttachmentPixelFormat = mtlView.depthStencilPixelFormat
        occlusionPipeline = try! device.makeRenderPipelineState(descriptor: occDesc)

        // Cube rendering
        let vDesc = MTLVertexDescriptor()
        vDesc.attributes[0].format = .float3
        vDesc.attributes[0].offset = 0
        vDesc.attributes[0].bufferIndex = 0

        vDesc.attributes[1].format = .float3
        vDesc.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vDesc.attributes[1].bufferIndex = 0

        vDesc.layouts[0].stride = MemoryLayout<SIMD3<Float>>.stride * 2

        let cubeDesc = MTLRenderPipelineDescriptor()
        cubeDesc.vertexFunction = library.makeFunction(name: "unlitColorVertex")
        cubeDesc.fragmentFunction = library.makeFunction(name: "unlitColorFragment")
        cubeDesc.colorAttachments[0].pixelFormat = mtlView.colorPixelFormat
        cubeDesc.depthAttachmentPixelFormat = mtlView.depthStencilPixelFormat
        cubeDesc.vertexDescriptor = vDesc

        cubePipeline = try! device.makeRenderPipelineState(descriptor: cubeDesc)

        // Depth state
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: ds)
    }
}

// MARK: - Rendering Helpers

extension OcclusionViewController {

    private func setupOcclusionMesh(width: Int, height: Int) {

        var vertices = [SIMD2<Float>]()
        vertices.reserveCapacity(width * height)

        for y in 0..<height {
            for x in 0..<width {
                vertices.append([
                    Float(x) / Float(width - 1),
                    Float(y) / Float(height - 1)
                ])
            }
        }

        var indices = [UInt32]()
        indices.reserveCapacity((width - 1) * (height - 1) * 6)

        for y in 0..<height - 1 {
            for x in 0..<width - 1 {
                let i = UInt32(y * width + x)
                indices.append(contentsOf: [
                    i, i + 1, i + UInt32(width),
                    i + 1, i + 1 + UInt32(width), i + UInt32(width)
                ])
            }
        }

        occVertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<SIMD2<Float>>.stride)

        occIndexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt32>.stride)

        occIndexCount = indices.count
    }

    private func setupCube() {
        struct Vertex { let pos: SIMD3<Float>; let color: SIMD3<Float> }

        let s: Float = 0.1

        let vertices: [Vertex] = [
            .init(pos: [-s,-s, s], color: [1,0,0]),
            .init(pos: [ s,-s, s], color: [0,1,0]),
            .init(pos: [ s, s, s], color: [0,0,1]),
            .init(pos: [-s, s, s], color: [1,1,0]),
            .init(pos: [-s,-s,-s], color: [1,0,1]),
            .init(pos: [ s,-s,-s], color: [0,1,1]),
            .init(pos: [ s, s,-s], color: [1,1,1]),
            .init(pos: [-s, s,-s], color: [0.2,0.2,0.2])
        ]

        let indices: [UInt16] = [
            0,1,2, 0,2,3,
            1,5,6, 1,6,2,
            5,4,7, 5,7,6,
            4,0,3, 4,3,7,
            3,2,6, 3,6,7,
            4,5,1, 4,1,0
        ]

        cubeVertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Vertex>.stride)

        cubeIndexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt16>.stride)

        cubeIndexCount = indices.count
    }

    private func drawOcclusionMesh(encoder: MTLRenderCommandEncoder,
                                   depthTexture: MTLTexture) {
        // Lazily create the occlusion mesh
        if !didCreateOcclusionMesh {
            setupOcclusionMesh(width: depthTexture.width,
                               height: depthTexture.height)
            didCreateOcclusionMesh = true
        }

        encoder.pushDebugGroup("Occlusion Mesh")
        encoder.setRenderPipelineState(occlusionPipeline)

        encoder.setVertexBuffer(occVertexBuffer, offset: 0, index: 0)

        var uniforms = OcclusionMeshUniforms(
            viewProj: projectionMatrix * viewMatrix,
            intrinsics: intrinsicsMatrix,
            extrinsics: extrinsicsMatrix,
            resolution: [
                Float(depthTexture.width),
                Float(depthTexture.height)
            ]
        )

        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<OcclusionMeshUniforms>.stride,
            index: 1)

        encoder.setVertexTexture(depthTexture, index: 0)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: occIndexCount,
            indexType: .uint32,
            indexBuffer: occIndexBuffer,
            indexBufferOffset: 0)

        encoder.popDebugGroup()
    }

    private func drawCube(encoder: MTLRenderCommandEncoder) {
        guard cubeIndexCount > 0 else { return }

        encoder.pushDebugGroup("Cube")
        encoder.setRenderPipelineState(cubePipeline)
        encoder.setVertexBuffer(cubeVertexBuffer, offset: 0, index: 0)

        // Cube placed 2m in front of camera
        var model = viewMatrix.inverse
        model.columns.3 = model * simd_float4(0, 0, -2, 1)

        // Apply yaw rotation
        let angle: Float = .pi / 4
        let rotationY = simd_float4x4(
            SIMD4(cos(angle), 0, sin(angle), 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(-sin(angle), 0, cos(angle), 0),
            SIMD4(0, 0, 0, 1)
        )

        // 2x scale
        let scaleMatrix = simd_float4x4(
            SIMD4(2,0,0,0),
            SIMD4(0,2,0,0),
            SIMD4(0,0,2,0),
            SIMD4(0,0,0,1)
        )

        model = model * rotationY * scaleMatrix

        var mvp = projectionMatrix * viewMatrix * model

        encoder.setVertexBytes(
            &mvp,
            length: MemoryLayout<float4x4>.stride,
            index: 1)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: cubeIndexCount,
            indexType: .uint16,
            indexBuffer: cubeIndexBuffer,
            indexBufferOffset: 0)

        encoder.popDebugGroup()
    }
}

// MARK: - MTKViewDelegate

extension OcclusionViewController : MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            fetchDepthData(),
            let depthTexture,
            let drawable = view.currentDrawable,
            let rpd = view.currentRenderPassDescriptor,
            let commandQueue
        else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd)!

        encoder.setDepthStencilState(depthState)

        drawOcclusionMesh(encoder: encoder, depthTexture: depthTexture)
        drawCube(encoder: encoder)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
