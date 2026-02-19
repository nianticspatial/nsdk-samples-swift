import UIKit
import ARKit
import SwiftyNsdk
import Metal
import MetalKit

class CaptureViewController: BaseARViewController {
    private var nsdkCapture: CaptureManager?
    private var isCapturing = false
    private var progressView: UIProgressView = UIProgressView()
    private var captureButton: UIButton?
    private var visualizationView: TextureView?

    // Metal resources for compositing
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var compositeKernel: MTLComputePipelineState?
    private var compositedTexture: MTLTexture?

    // Cached dimensions
    private var cachedCompositeWidth: Int = 0
    private var cachedCompositeHeight: Int = 0

    // Stripe pattern parameters
    private var stripeStride: UInt32 = 7
    private var stripeRedPixels: UInt32 = 5

    override func viewDidLoad() {
        super.viewDidLoad()
        setupMetalResources()
    }

    private func setupMetalResources() {
        device = MTLCreateSystemDefaultDevice()
        guard let device = device else {
            print("Failed to create Metal device")
            return
        }

        commandQueue = device.makeCommandQueue()

        // Create compute kernel for compositing
        guard let library = device.makeDefaultLibrary(),
              let kernelFunction = library.makeFunction(name: "scanning_composite_kernel") else {
            print("Failed to load scanning composite kernel")
            return
        }

        do {
            compositeKernel = try device.makeComputePipelineState(function: kernelFunction)
        } catch {
            print("Failed to create compute pipeline state: \(error)")
        }

        // Adjust stripe parameters based on expected screen size
        // Can be made dynamic based on actual viewport if needed
        stripeStride = 7
        stripeRedPixels = 5
    }

    override func setupUI() {
        super.setupUI()

        self.title = "Capture"
        helpLabel.text = "Capture Sample Help\n\nThis sample creates and saves a recording that can later" +
        " be used for NSDK Playback\nTO USE:\nPress ‘Start Capture’ to start capturing." +
        " A simple visualization will indicate the parts covered by the capture, " +
        "with red stripes indicating the missed areas. After the capture stops, " +
        "the capture will automatically be exported to Niantic Spatial’s " +
        "recorder format and you can use the result archive for NSDK Playback."

        self.captureButton = addButton(buttonTitle: "Start Capture", onClickAction: #selector(handleCaptureButtonTap))

        // Set up the visualization view using standard TextureView
        visualizationView = TextureView(
            frame: view.bounds,
            vertexShader: "scanningVertexShader",
            fragmentShader: "scanningFragmentShader"
        )
        visualizationView!.isOpaque = true
        visualizationView!.translatesAutoresizingMaskIntoConstraints = false
        visualizationView!.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        visualizationView!.isHidden = true  // Hidden by default, shown when capture starts
        arView.addSubview(visualizationView!)

        NSLayoutConstraint.activate([
            visualizationView!.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            visualizationView!.topAnchor.constraint(equalTo: view.topAnchor),
            visualizationView!.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            visualizationView!.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Setup progress view
        progressView.progressTintColor = .white
        progressView.trackTintColor = .systemGray
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.isHidden = true
        view.addSubview(progressView)

        NSLayoutConstraint.activate([
            progressView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progressView.bottomAnchor.constraint(equalTo: captureButton!.topAnchor, constant: -20),
            progressView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            progressView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            progressView.heightAnchor.constraint(equalToConstant: 4)
        ])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        nsdkCapture?.stop()
    }

    private func updateVisualization() {
        guard let capture = nsdkCapture,
              let textureView = visualizationView else {
            return
        }

        // Update the raycast textures from the capture session (raw inputs)
        if capture.updateRaycastTextures() {
            // Composite the raycast texture with stripe pattern
            if let rgbaTexture = capture.rgbaTexture {
                compositeVisualization(from: rgbaTexture)

                // Display the composited result
                if let composited = compositedTexture {
                    textureView.setTexture(copyFrom: composited)
                    // Display transform is automatically handled by TextureView
                }
            }
        }
    }

    /// Composites the raycast texture with stripe pattern using a compute kernel.
    /// The result is stored in `compositedTexture`.
    private func compositeVisualization(from source: MTLTexture) {
        guard let device = device,
              let kernel = compositeKernel,
              let queue = commandQueue,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        let width = source.width
        let height = source.height

        // Create or recreate output texture if needed
        if compositedTexture == nil || cachedCompositeWidth != width || cachedCompositeHeight != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .shared

            compositedTexture = device.makeTexture(descriptor: descriptor)
            cachedCompositeWidth = width
            cachedCompositeHeight = height
        }

        guard let output = compositedTexture else { return }

        // Set up uniforms
        struct CompositeUniforms {
            var stripeStride: UInt32
            var stripeRedPixels: UInt32
        }
        var uniforms = CompositeUniforms(
            stripeStride: stripeStride,
            stripeRedPixels: stripeRedPixels
        )

        // Set up compute pipeline
        encoder.setComputePipelineState(kernel)
        encoder.setTexture(output, index: 0)
        encoder.setTexture(source, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)

        // Calculate threadgroup size
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
    }

    private func showProgressBar() {
        DispatchQueue.main.async { [weak self] in
            self?.progressView.isHidden = false
            self?.progressView.progress = 0.0
        }
    }

    private func hideProgressBar() {
        DispatchQueue.main.async { [weak self] in
            self?.progressView.isHidden = true
        }
    }

    private func updateProgress(_ progress: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.progressView.setProgress(progress, animated: true)
        }
    }

    @objc private func handleCaptureButtonTap() {
        if nsdkCapture == nil {
            nsdkCapture = CaptureManager(nsdk: nsdkManager!.session,
                                           enableRaycastVisualization: true,
                                           enableVoxelVisualization: false)
        }

        if isCapturing {
            captureButton?.setTitle("Saving...", for: .normal)
            captureButton?.isEnabled = false
            isCapturing = false

            // Hide visualization when capturing stops
            visualizationView?.isHidden = true
            visualizationView?.reset()

            Task {
                let saved = await self.nsdkCapture!.save(withTimeoutSeconds: 6)

                if saved == true {
                    DispatchQueue.main.async {
                        self.updateInfoLabel(text: "Archiving capture...")
                    }
                    self.showProgressBar()

                    let result = await self.nsdkCapture?.archiveRecentSave(
                        progressCallback: { [weak self] progress in
                            self?.updateProgress(progress)
                        }
                    )

                    self.hideProgressBar()
                    DispatchQueue.main.async {
                        if let result = result, result.success, let archivePath = result.archivePath {
                            self.updateInfoLabel(text: "Capture successfully saved and archived.")
                            // Present share sheet to let user save or share the archive
                            self.presentShareSheet(for: archivePath)
                        } else {
                            self.updateInfoLabel(text: "Failed to archive capture.")
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.updateInfoLabel(text: "Failed to save capture.")
                    }
                }


                self.nsdkCapture?.stop()
                DispatchQueue.main.async {
                    self.captureButton?.setTitle("Start Capture", for: .normal)
                    self.captureButton?.isEnabled = true // Re-enable button
                }
            }
            return
        } else {
            if (nsdkCapture != nil) {
                nsdkCapture?.start()
                captureButton?.setTitle("Stop Capture", for: .normal)

                isCapturing = true

                // Show visualization when capture starts
                visualizationView?.isHidden = false
            } else {
                updateInfoLabel(text: "Failed to start capture session.")
                captureButton?.isUserInteractionEnabled = false
            }

        }
    }

    // MARK: - Share Sheet

    private func presentShareSheet(for filePath: String) {
        let fileURL = URL(fileURLWithPath: filePath)

        // Check if file exists
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("Error: Archive file not found at path: \(filePath)")
            updateInfoLabel(text: "Archive file not found.")
            return
        }

        // Create activity view controller for iPhone
        let activityViewController = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )

        // Present the share sheet
        self.present(activityViewController, animated: true) {
            print("Share sheet presented for: \(filePath)")
        }
    }

    // MARK: - ARSessionDelegate Override

    override func session(_ session: ARSession, didUpdate frame: ARFrame) {
        super.session(session, didUpdate: frame)

        // Update the raycast visualization if capture is active
        if isCapturing {
            updateVisualization()
        }
    }
}
