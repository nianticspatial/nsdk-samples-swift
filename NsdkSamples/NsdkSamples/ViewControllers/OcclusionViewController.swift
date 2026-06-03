// Copyright 2026 Niantic Spatial.

import UIKit
import Metal
import MetalKit
import simd
import NSDK
import Combine

final class OcclusionViewController: UIViewController {

    // MARK: - AR

    private let arManager: ARManager

    private var depthSession: NSDKDepthSession!
    private var viewModel: OcclusionViewModel!

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

    // MARK: - Depth Data (from ViewModel)

    private var currentDepthTexture: MTLTexture?
    private var intrinsicsMatrix = matrix_identity_float3x3
    private var extrinsicsMatrix = matrix_identity_float4x4

    // MARK: - Cube distance (UI)

    private static let cubeDistanceMin: Float = 1.0
    private static let cubeDistanceMax: Float = 5.0
    private var cubeDistanceFromCamera: Float = 2.0
    private let cubeDistanceSlider = UISlider()
    private let cubeDistanceLabel = UILabel()

    // MARK: - UI

    private let statusOverlay = ARStatusOverlay()
    private let helpOverlay = HelpOverlayUIKitView(helpText: OcclusionViewController.helpText)

    // MARK: - Combine

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(arManager: ARManager) {
        self.arManager = arManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Occlusion"
        view.backgroundColor = .darkGray

        arManager.nsdkView.setup(in: view)
        setupMetalView()
        setupPipelines()
        setupCube()
        setupCubeDistanceSlider()
        statusOverlay.setup(in: view)
        helpOverlay.setup(in: view, anchoredBelow: statusOverlay.bottomAnchor, navigationItem: navigationItem)

        let session = arManager.nsdkSession.acquireDepthSession()
        let config = NSDKDepthSession.Configuration()
        do {
            try session.configure(with: config)
        } catch {
            print("[OcclusionViewController2] Failed to configure depth session: \(error)")
        }
        depthSession = session

        viewModel = OcclusionViewModel(depthSession: depthSession)

        viewModel.$depthTexture
            .receive(on: DispatchQueue.main)
            .sink { [weak self] texture in
                self?.currentDepthTexture = texture
            }
            .store(in: &cancellables)

        viewModel.$intrinsics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] matrix in
                self?.intrinsicsMatrix = matrix
            }
            .store(in: &cancellables)

        viewModel.$extrinsics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] matrix in
                self?.extrinsicsMatrix = matrix
            }
            .store(in: &cancellables)

        arManager.frameState.$trackingState
            .combineLatest(arManager.frameState.$anchorsIsEmpty)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trackingState, anchorsIsEmpty in
                self?.statusOverlay.update(
                    trackingState: trackingState,
                    anchorsIsEmpty: anchorsIsEmpty
                )
            }
            .store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        depthSession.start()
        arManager.startSession()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        depthSession.stop()
        arManager.stopSession()
        if isMovingFromParent {
            arManager.nsdkSession.destroy(depthSession)
        }
    }

    // MARK: - Help

    private static let helpText = "Occlusion Sample Help\n\n This sample uses NSDK depth to hide a virtual cube behind real geometry." +
    "\n\n TO USE: use the slider to adjust the distance of the cube from the camera."
    // MARK: - Metal Setup

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
        mtkView.translatesAutoresizingMaskIntoConstraints = false

        arManager.nsdkView.addSubview(mtkView)

        NSLayoutConstraint.activate([
            mtkView.topAnchor.constraint(equalTo: arManager.nsdkView.topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: arManager.nsdkView.bottomAnchor),
            mtkView.leadingAnchor.constraint(equalTo: arManager.nsdkView.leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: arManager.nsdkView.trailingAnchor),
        ])

        self.mtlView = mtkView
    }

    private func setupPipelines() {
        let library = try! device.makeDefaultLibrary(bundle: .main)

        let occDesc = MTLRenderPipelineDescriptor()
        occDesc.vertexFunction = library.makeFunction(name: "occlusionMeshVertex")
        occDesc.fragmentFunction = library.makeFunction(name: "occlusionMeshFragment")
        occDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        occDesc.colorAttachments[0].writeMask = []
        occDesc.depthAttachmentPixelFormat = .depth32Float
        occlusionPipeline = try! device.makeRenderPipelineState(descriptor: occDesc)

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
        cubeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        cubeDesc.depthAttachmentPixelFormat = .depth32Float
        cubeDesc.vertexDescriptor = vDesc
        cubePipeline = try! device.makeRenderPipelineState(descriptor: cubeDesc)

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: ds)
    }

    // MARK: - Cube Distance Slider

    private func setupCubeDistanceSlider() {
        cubeDistanceSlider.minimumValue = Self.cubeDistanceMin
        cubeDistanceSlider.maximumValue = Self.cubeDistanceMax
        cubeDistanceSlider.value = cubeDistanceFromCamera
        cubeDistanceSlider.translatesAutoresizingMaskIntoConstraints = false
        cubeDistanceSlider.addTarget(self, action: #selector(cubeDistanceSliderChanged(_:)), for: .valueChanged)
        view.addSubview(cubeDistanceSlider)

        cubeDistanceLabel.text = String(format: "Cube: %.1f m", cubeDistanceFromCamera)
        cubeDistanceLabel.textColor = .white
        cubeDistanceLabel.font = .systemFont(ofSize: 12)
        cubeDistanceLabel.textAlignment = .center
        cubeDistanceLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cubeDistanceLabel)

        NSLayoutConstraint.activate([
            cubeDistanceSlider.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            cubeDistanceSlider.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            cubeDistanceSlider.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            cubeDistanceLabel.centerXAnchor.constraint(equalTo: cubeDistanceSlider.centerXAnchor),
            cubeDistanceLabel.bottomAnchor.constraint(equalTo: cubeDistanceSlider.topAnchor, constant: -5),
        ])
    }

    @objc private func cubeDistanceSliderChanged(_ sender: UISlider) {
        cubeDistanceFromCamera = sender.value
        cubeDistanceLabel.text = String(format: "Cube: %.1f m", cubeDistanceFromCamera)
    }
}

// MARK: - Geometry Setup

extension OcclusionViewController {

    private func setupOcclusionMesh(width: Int, height: Int) {
        var vertices = [SIMD2<Float>]()
        vertices.reserveCapacity(width * height)

        for y in 0..<height {
            for x in 0..<width {
                vertices.append([
                    Float(x) / Float(width - 1),
                    Float(y) / Float(height - 1),
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
                    i + 1, i + 1 + UInt32(width), i + UInt32(width),
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
            .init(pos: [-s, -s, s], color: [1, 0, 0]),
            .init(pos: [s, -s, s], color: [0, 1, 0]),
            .init(pos: [s, s, s], color: [0, 0, 1]),
            .init(pos: [-s, s, s], color: [1, 1, 0]),
            .init(pos: [-s, -s, -s], color: [1, 0, 1]),
            .init(pos: [s, -s, -s], color: [0, 1, 1]),
            .init(pos: [s, s, -s], color: [1, 1, 1]),
            .init(pos: [-s, s, -s], color: [0.2, 0.2, 0.2]),
        ]

        let indices: [UInt16] = [
            0, 1, 2, 0, 2, 3,
            1, 5, 6, 1, 6, 2,
            5, 4, 7, 5, 7, 6,
            4, 0, 3, 4, 3, 7,
            3, 2, 6, 3, 6, 7,
            4, 5, 1, 4, 1, 0,
        ]

        cubeVertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Vertex>.stride)

        cubeIndexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt16>.stride)

        cubeIndexCount = indices.count
    }
}

// MARK: - Rendering

extension OcclusionViewController {

    struct OcclusionMeshUniforms {
        var viewProj: simd_float4x4
        var intrinsics: simd_float3x3
        var extrinsics: simd_float4x4
        var resolution: simd_float2
    }

    private func drawOcclusionMesh(encoder: MTLRenderCommandEncoder, depthTexture: MTLTexture,
                                   viewMatrix: matrix_float4x4, projectionMatrix: matrix_float4x4) {
        if !didCreateOcclusionMesh {
            setupOcclusionMesh(width: depthTexture.width, height: depthTexture.height)
            didCreateOcclusionMesh = true
        }

        encoder.pushDebugGroup("Occlusion Mesh")
        encoder.setRenderPipelineState(occlusionPipeline)
        encoder.setVertexBuffer(occVertexBuffer, offset: 0, index: 0)

        var uniforms = OcclusionMeshUniforms(
            viewProj: projectionMatrix * viewMatrix,
            intrinsics: intrinsicsMatrix,
            extrinsics: extrinsicsMatrix,
            resolution: [Float(depthTexture.width), Float(depthTexture.height)]
        )

        encoder.setVertexBytes(&uniforms, length: MemoryLayout<OcclusionMeshUniforms>.stride, index: 1)
        encoder.setVertexTexture(depthTexture, index: 0)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: occIndexCount,
            indexType: .uint32,
            indexBuffer: occIndexBuffer,
            indexBufferOffset: 0)

        encoder.popDebugGroup()
    }

    private func drawCube(encoder: MTLRenderCommandEncoder,
                          viewMatrix: matrix_float4x4, projectionMatrix: matrix_float4x4) {
        guard cubeIndexCount > 0 else { return }

        encoder.pushDebugGroup("Cube")
        encoder.setRenderPipelineState(cubePipeline)
        encoder.setVertexBuffer(cubeVertexBuffer, offset: 0, index: 0)

        var model = viewMatrix.inverse
        let distance = max(Self.cubeDistanceMin, min(Self.cubeDistanceMax, cubeDistanceFromCamera))
        model.columns.3 = model * simd_float4(0, 0, -distance, 1)

        let angle: Float = .pi / 4
        let rotationY = simd_float4x4(
            SIMD4(cos(angle), 0, sin(angle), 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(-sin(angle), 0, cos(angle), 0),
            SIMD4(0, 0, 0, 1)
        )

        let scaleMatrix = simd_float4x4(
            SIMD4(2, 0, 0, 0),
            SIMD4(0, 2, 0, 0),
            SIMD4(0, 0, 2, 0),
            SIMD4(0, 0, 0, 1)
        )

        model = model * rotationY * scaleMatrix

        var mvp = projectionMatrix * viewMatrix * model

        encoder.setVertexBytes(&mvp, length: MemoryLayout<float4x4>.stride, index: 1)

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

extension OcclusionViewController: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange _: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let depthTexture = currentDepthTexture,
            let drawable = view.currentDrawable,
            let rpd = view.currentRenderPassDescriptor,
            let commandQueue
        else { return }

        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        guard let camera = arManager.nsdkView.getCamera() else { return }

        let viewportRect = camera.viewportRect(fittingIn: view.drawableSize, displayOrientation: orientation)
        let viewMatrix = camera.viewMatrix(for: orientation)
        let projectionMatrix = camera.projectionMatrix(
            for: orientation,
            viewportSize: viewportRect.size,
            zNear: 0.01,
            zFar: 10.0
        )

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd)!

        let viewport = MTLViewport(
            originX: viewportRect.origin.x,
            originY: viewportRect.origin.y,
            width: viewportRect.width,
            height: viewportRect.height,
            znear: 0,
            zfar: 1
        )
        encoder.setViewport(viewport)
        encoder.setDepthStencilState(depthState)

        drawOcclusionMesh(encoder: encoder, depthTexture: depthTexture,
                          viewMatrix: viewMatrix, projectionMatrix: projectionMatrix)
        drawCube(encoder: encoder, viewMatrix: viewMatrix, projectionMatrix: projectionMatrix)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
