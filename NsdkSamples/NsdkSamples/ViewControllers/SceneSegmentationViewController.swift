// Copyright 2026 Niantic Spatial.

import UIKit
import Metal
import NSDK
import Combine

final class SceneSegmentationViewController: UIViewController {

    // MARK: - AR

    private let arManager: ARManager

    // MARK: - Session + ViewModel

    private var sceneSegmentationSession: NSDKSceneSegmentationSession!
    private var viewModel: SceneSegmentationViewModel!

    // MARK: - UI

    private var imageView: TextureView!
    private let toggleButton = UIButton(type: .system)
    private let transparencySlider = UISlider()
    private let sliderLabel = UILabel()
    private let channelPicker = UIPickerView()
    private let channelButton = UIButton(type: .system)
    private let statusOverlay = ARStatusOverlay()
    private let helpOverlay = HelpOverlayView(helpText: SceneSegmentationViewController.helpText)

    // MARK: - Channel State

    private let channels = SceneSegmentationChannels.allChannels
    private var selectedChannelIndex = 0
    private var isChannelPickerVisible = false

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
        title = "Scene Segmentation"
        view.backgroundColor = .darkGray

        arManager.nsdkView.setup(in: view)
        setupImageView()
        setupTransparencyControls()
        setupChannelPicker()
        setupChannelButton()
        setupToggleButton()
        applyConstraints()
        statusOverlay.setup(in: view)
        helpOverlay.setup(in: view, anchoredBelow: statusOverlay.bottomAnchor, navigationItem: navigationItem)

        let session = arManager.nsdkSession.acquireSceneSegmentationSession()
        let config = NSDKSceneSegmentationSession.Configuration()
        do {
            try session.configure(with: config)
        } catch {
            print("[SceneSegmentationViewController2] Failed to configure semantics session: \(error)")
        }
        sceneSegmentationSession = session

        viewModel = SceneSegmentationViewModel(sceneSegmentationSession: sceneSegmentationSession, frameState: arManager.frameState)

        viewModel.$segmentationTexture
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

        if let groundIndex = channels.firstIndex(where: { $0 == .ground }) {
            selectedChannelIndex = groundIndex
        }
        sceneSegmentationSession.confidenceChannel = channels[selectedChannelIndex]
        updateChannelButtonTitle()

        channelPicker.reloadAllComponents()
        channelPicker.selectRow(selectedChannelIndex, inComponent: 0, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        sceneSegmentationSession.start()
        arManager.startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneSegmentationSession.stop()
        arManager.stopSession()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent {
            arManager.nsdkSession.destroy(sceneSegmentationSession)
        }
    }

    // MARK: - Help

    private static let helpText =
        "Scene Segmentation Sample Help\n\n" +
        "This sample uses our scene segmentation feature and a shader to represent it, " +
        "coloring pink where a channel is detected and blue where it is not.\n\n" +
        "TO USE:\n" +
        "Select a semantic channel from the drop-down menu, and use the transparency " +
        "slider to see the color highlight overlaid on the camera feed."

    // MARK: - Setup

    private func setupImageView() {
        imageView = TextureView(
            frame: view.bounds,
            vertexShader: "semanticVertexShader",
            fragmentShader: "semanticFragmentShader"
        )
        imageView.opacity = 0.5
        imageView.isOpaque = false
        imageView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        arManager.nsdkView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: arManager.nsdkView.leadingAnchor),
            imageView.topAnchor.constraint(equalTo: arManager.nsdkView.topAnchor),
            imageView.trailingAnchor.constraint(equalTo: arManager.nsdkView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: arManager.nsdkView.bottomAnchor),
        ])
    }

    private func setupTransparencyControls() {
        transparencySlider.minimumValue = 0
        transparencySlider.maximumValue = 1
        transparencySlider.value = 0.5
        transparencySlider.translatesAutoresizingMaskIntoConstraints = false
        transparencySlider.addTarget(self, action: #selector(handleSlider(_:)), for: .valueChanged)
        view.addSubview(transparencySlider)

        sliderLabel.text = "Transparency: 50%"
        sliderLabel.textColor = .white
        sliderLabel.font = .systemFont(ofSize: 12)
        sliderLabel.textAlignment = .center
        sliderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sliderLabel)
    }

    private func setupChannelPicker() {
        channelPicker.dataSource = self
        channelPicker.delegate = self
        channelPicker.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        channelPicker.layer.cornerRadius = 8
        channelPicker.isHidden = true
        channelPicker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(channelPicker)
    }

    private func setupChannelButton() {
        updateChannelButtonTitle()
        channelButton.setTitleColor(.white, for: .normal)
        channelButton.backgroundColor = .systemBlue
        channelButton.layer.cornerRadius = 8
        channelButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        channelButton.translatesAutoresizingMaskIntoConstraints = false
        channelButton.addTarget(self, action: #selector(toggleChannelPicker), for: .touchUpInside)
        view.addSubview(channelButton)
    }

    private func setupToggleButton() {
        toggleButton.setTitle("Hide", for: .normal)
        toggleButton.setTitleColor(.white, for: .normal)
        toggleButton.backgroundColor = .systemBlue
        toggleButton.layer.cornerRadius = 8
        toggleButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.addTarget(self, action: #selector(handleToggle), for: .touchUpInside)
        view.addSubview(toggleButton)
    }

    private func applyConstraints() {
        NSLayoutConstraint.activate([
            transparencySlider.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            transparencySlider.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            transparencySlider.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),

            sliderLabel.centerXAnchor.constraint(equalTo: transparencySlider.centerXAnchor),
            sliderLabel.bottomAnchor.constraint(equalTo: transparencySlider.topAnchor, constant: -5),

            channelButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            channelButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            channelButton.bottomAnchor.constraint(equalTo: sliderLabel.topAnchor, constant: -10),
            channelButton.heightAnchor.constraint(equalToConstant: 44),

            channelPicker.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            channelPicker.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            channelPicker.bottomAnchor.constraint(equalTo: channelButton.topAnchor, constant: -5),
            channelPicker.heightAnchor.constraint(equalToConstant: 120),

            toggleButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            toggleButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            toggleButton.widthAnchor.constraint(equalToConstant: 180),
            toggleButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

}

// MARK: - Actions

extension SceneSegmentationViewController {

    @objc private func handleSlider(_ sender: UISlider) {
        imageView.opacity = sender.value
        sliderLabel.text = "Transparency: \(Int(sender.value * 100))%"
    }

    @objc private func handleToggle() {
        imageView.reset()
        imageView.isHidden.toggle()
        toggleButton.setTitle(imageView.isHidden ? "Show" : "Hide", for: .normal)
    }

    @objc private func toggleChannelPicker() {
        isChannelPickerVisible.toggle()

        UIView.animate(withDuration: 0.3) {
            self.channelPicker.isHidden = !self.isChannelPickerVisible
            self.channelButton.alpha = self.isChannelPickerVisible ? 0.7 : 1.0
        }

        updateChannelButtonTitle()
    }
}

// MARK: - Channel Helpers

extension SceneSegmentationViewController {

    private func updateChannelButtonTitle() {
        let arrow = isChannelPickerVisible ? "▲" : "▼"
        let name = formatChannelName(channels[selectedChannelIndex])
        channelButton.setTitle("Semantic Channel: \(name) \(arrow)", for: .normal)
    }

    private func formatChannelName(_ channel: SceneSegmentationChannels) -> String {
        channel.channelDebugName
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

// MARK: - UIPickerView DataSource & Delegate

extension SceneSegmentationViewController: UIPickerViewDataSource, UIPickerViewDelegate {

    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        channels.count
    }

    func pickerView(_ pickerView: UIPickerView, viewForRow row: Int,
                    forComponent component: Int, reusing view: UIView?) -> UIView {
        let label = (view as? UILabel) ?? {
            let l = UILabel()
            l.textAlignment = .center
            l.font = .systemFont(ofSize: 17)
            return l
        }()
        label.text = formatChannelName(channels[row])
        label.textColor = .white
        return label
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        guard row < channels.count else { return }
        selectedChannelIndex = row
        sceneSegmentationSession.confidenceChannel = channels[row]

        updateChannelButtonTitle()
    }
}
