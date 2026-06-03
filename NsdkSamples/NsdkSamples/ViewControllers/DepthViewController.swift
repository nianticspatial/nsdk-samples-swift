// Copyright 2026 Niantic Spatial.

import UIKit
import Metal
import NSDK
import Combine

final class DepthViewController: UIViewController {

    // MARK: - AR

    private let arManager: ARManager

    // MARK: - Session + ViewModel

    private var depthSession: NSDKDepthSession!
    private var viewModel: DepthViewModel!

    // MARK: - UI

    private var imageView: TextureView!
    private let toggleButton = UIButton(type: .system)
    private let transparencySlider = UISlider()
    private let sliderLabel = UILabel()
    private let statusOverlay = ARStatusOverlay()
    private let helpOverlay = HelpOverlayUIKitView(helpText: DepthViewController.helpText)

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
        title = "Depth"
        view.backgroundColor = .darkGray

        arManager.nsdkView.setup(in: view)
        setupImageView()
        setupControls()
        statusOverlay.setup(in: view)
        helpOverlay.setup(in: view, anchoredBelow: statusOverlay.bottomAnchor, navigationItem: navigationItem)

        let session = arManager.nsdkSession.acquireDepthSession()
        let config = NSDKDepthSession.Configuration()
        do {
            try session.configure(with: config)
        } catch {
            print("[DepthViewController2] Failed to configure depth session: \(error)")
        }
        depthSession = session

        viewModel = DepthViewModel(depthSession: depthSession, frameState: arManager.frameState)

        viewModel.$depthTexture
            .receive(on: DispatchQueue.main)
            .sink { [weak self] texture in
                guard let self, let texture else { return }
                self.imageView.setTexture(copyFrom: texture)
            }
            .store(in: &cancellables)

        viewModel.$reprojection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] matrix in
                self?.imageView.setReprojection(matrix)
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

    private static let helpText =
        "Depth Sample Help\n\n" +
        "This sample displays a representation of the depth in a color scale from blue, " +
        "for closest objects, to red, for the farthest.\n\n" +
        "TO USE:\n" +
        "The display starts automatically. Use the transparency slider to blend the depth " +
        "view with the camera feed, or press the \"Hide\" button to fully hide it and see " +
        "the unchanged camera feed."

    // MARK: - Setup

    private func setupImageView() {
        imageView = TextureView(
            frame: view.bounds,
            vertexShader: "depthVertexShader",
            fragmentShader: "depthFragmentShader"
        )
        imageView.isOpaque = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        arManager.nsdkView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: arManager.nsdkView.leadingAnchor),
            imageView.topAnchor.constraint(equalTo: arManager.nsdkView.topAnchor),
            imageView.trailingAnchor.constraint(equalTo: arManager.nsdkView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: arManager.nsdkView.bottomAnchor),
        ])
    }

    private func setupControls() {
        toggleButton.setTitle("Hide", for: .normal)
        toggleButton.setTitleColor(.white, for: .normal)
        toggleButton.backgroundColor = .systemBlue
        toggleButton.layer.cornerRadius = 8
        toggleButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.addTarget(self, action: #selector(handleToggle), for: .touchUpInside)
        view.addSubview(toggleButton)

        transparencySlider.minimumValue = 0
        transparencySlider.maximumValue = 1
        transparencySlider.value = 1
        transparencySlider.translatesAutoresizingMaskIntoConstraints = false
        transparencySlider.addTarget(self, action: #selector(handleSlider(_:)), for: .valueChanged)
        view.addSubview(transparencySlider)

        sliderLabel.text = "Transparency: 100%"
        sliderLabel.textColor = .white
        sliderLabel.font = .systemFont(ofSize: 12)
        sliderLabel.textAlignment = .center
        sliderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sliderLabel)

        NSLayoutConstraint.activate([
            toggleButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            toggleButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            toggleButton.widthAnchor.constraint(equalToConstant: 180),
            toggleButton.heightAnchor.constraint(equalToConstant: 44),

            transparencySlider.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            transparencySlider.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            transparencySlider.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),

            sliderLabel.centerXAnchor.constraint(equalTo: transparencySlider.centerXAnchor),
            sliderLabel.bottomAnchor.constraint(equalTo: transparencySlider.topAnchor, constant: -5),
        ])
    }
}

// MARK: - Actions

extension DepthViewController {
    @objc private func handleSlider(_ sender: UISlider) {
        imageView.opacity = sender.value
        sliderLabel.text = "Transparency: \(Int(sender.value * 100))%"
    }

    @objc private func handleToggle() {
        imageView.reset()
        imageView.isHidden.toggle()
        toggleButton.setTitle(imageView.isHidden ? "Show" : "Hide", for: .normal)
    }
}
