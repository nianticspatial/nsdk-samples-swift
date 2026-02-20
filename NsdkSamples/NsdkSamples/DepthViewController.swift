//
//  DepthViewController.swift
//
//  Displays depth inference results using a Metal-powered TextureView,
//  optionally reprojected into the live camera frame.
//

import UIKit
import ARKit
import Metal
import MetalKit
import SwiftyNsdk

final class DepthViewController: BaseARViewController {

    // MARK: - Depth + GPU Resources

    private var manager: DepthManager?
    private var texture: MTLTexture?
    private let device = MTLCreateSystemDefaultDevice()
    private var lastFrameId: UInt64 = 0

    // MARK: - UI Components

    private var imageView: TextureView!
    private let button = UIButton(type: .system)
    private let transparencySlider = UISlider()
    private let sliderLabel = UILabel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        self.title = "Depth"
        helpLabel.text = "Depth Sample Help\n\nThis sample displays a representation of the depth in a color scale from blue, for closts objects, to red, for the farthest.\n TO USE: \n The display starts automatically, and you can use the transparency bar to set see the camera view. Or press the \"Hide\" button to fully hide it and see the unchanged camera feed."

        setupDepthManager()
        setupImageView()
        setupControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        manager?.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        manager?.stop()
    }

    // MARK: - Setup

    private func setupDepthManager() {
        guard let nsdk = nsdkManager?.session else {
            assertionFailure("AR session missing.")
            return
        }
        manager = DepthManager(nsdk: nsdk)
    }

    private func setupImageView() {
        imageView = TextureView(
            frame: view.bounds,
            vertexShader: "depthVertexShader",
            fragmentShader: "depthFragmentShader"
        )

        imageView.isOpaque = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        arView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            imageView.topAnchor.constraint(equalTo: arView.topAnchor),
            imageView.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: arView.bottomAnchor)
        ])
    }

    private func setupControls() {
        setupToggleButton()
        setupTransparencyControls()
    }

    private func setupToggleButton() {
        button.setTitle("Hide", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 8
        button.titleLabel?.font = .boldSystemFont(ofSize: 16)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(handleButtonTap), for: .touchUpInside)

        view.addSubview(button)

        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            button.widthAnchor.constraint(equalToConstant: 180),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func setupTransparencyControls() {
        // Slider
        transparencySlider.minimumValue = 0
        transparencySlider.maximumValue = 1
        transparencySlider.value = 1
        transparencySlider.translatesAutoresizingMaskIntoConstraints = false
        transparencySlider.addTarget(self, action: #selector(transparencySliderChanged(_:)), for: .valueChanged)
        view.addSubview(transparencySlider)

        // Label
        sliderLabel.text = "Transparency: 100%"
        sliderLabel.textColor = .white
        sliderLabel.font = .systemFont(ofSize: 12)
        sliderLabel.textAlignment = .center
        sliderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sliderLabel)

        NSLayoutConstraint.activate([
            transparencySlider.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            transparencySlider.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            transparencySlider.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),

            sliderLabel.centerXAnchor.constraint(equalTo: transparencySlider.centerXAnchor),
            sliderLabel.bottomAnchor.constraint(equalTo: transparencySlider.topAnchor, constant: -5)
        ])
    }

    // MARK: - ARSession Delegate

    override func session(_ session: ARSession, didUpdate frame: ARFrame) {
        super.session(session, didUpdate: frame)

        guard let device else {
            assertionFailure("Metal device unavailable.")
            return
        }

        guard !imageView.isHidden,
              let manager,
              let result = manager.latestDepth()
        else { return }

        // Update texture only when a new depth frame arrives
        if result.frameId != lastFrameId {
            lastFrameId = result.frameId

            let didUpdate = TextureUtils.createOrUpdateTexture(
                from: result.image,
                texture: &texture,
                device: device
            )

            // Only update the view if GPU texture content actually changed
            if didUpdate, let texture {
                imageView.setTexture(copyFrom: texture)
            }
        }

        // Reprojection update
        imageView.setReprojection(result.calculateReprojection(to: frame.camera.transform) ?? matrix_identity_float3x3)
    }
}

// MARK: - UI Actions

extension DepthViewController {
    @objc private func transparencySliderChanged(_ sender: UISlider) {
        imageView.opacity = sender.value
        let percentage = Int(sender.value * 100)
        sliderLabel.text = "Transparency: \(percentage)%"
    }

    @objc private func handleButtonTap() {
        imageView.reset()
        imageView.isHidden.toggle()
        button.setTitle(imageView.isHidden ? "Show" : "Hide", for: .normal)
    }
}
