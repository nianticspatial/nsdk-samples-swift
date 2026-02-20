//
//  SceneSegmentationController.swift
//
//  Displays Scene Segmentation results using a Metal-powered TextureView,
//  optionally reprojected into the live camera frame.
//

import UIKit
import ARKit
import SwiftyNsdk
import Metal

final class SceneSegmentationViewController: BaseARViewController {

    // MARK: - Semantics + GPU Resources

    private var manager: SceneSegmentationManager?
    private var texture: MTLTexture?
    private let device = MTLCreateSystemDefaultDevice()
    private var lastFrameId: UInt64 = 0

    // MARK: - UI Components

    private var imageView: TextureView!
    private let infoLabel = UILabel()
    private let button = UIButton(type: .system)
    private let transparencySlider = UISlider()
    private let sliderLabel = UILabel()
    private let channelPicker = UIPickerView()
    private let channelButton = UIButton(type: .system)

    // MARK: - State

    private var isChannelPickerVisible = false
    private var channels: [SemanticsChannelName] = []
    private var selectedChannelIndex = 5  // default: "person"
    private var areChannelsLoaded = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        self.title = "Scene Segmentation"
        helpLabel.text = "Scene Segmentation Sample Help\n\n This sample uses our Scene Segmentation feature and a shader to represent them coloring pink where found and blue where not.\n\n TO USE: \n select a semantic channel from the drop down menu, and set the transparency to see the color highlight."

        setupSemanticsManager()
        setupImageView()
        setupInfoLabel()
        setupTransparencyControls()
        setupChannelPicker()
        setupChannelButton()
        setupMainToggleButton()
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

    private func setupSemanticsManager() {
        guard let nsdk = nsdkManager?.session else {
            assertionFailure("AR session missing.")
            return
        }
        manager = SceneSegmentationManager(nsdk: nsdk)
    }

    private func setupImageView() {
        imageView = TextureView(
            frame: view.bounds,
            vertexShader: "semanticVertexShader",
            fragmentShader: "semanticFragmentShader"
        )

        imageView.opacity = 0.5
        imageView.isOpaque = false
        imageView.clearColor = MTLClearColorMake(0, 0, 0, 0)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        arView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            imageView.topAnchor.constraint(equalTo: arView.topAnchor),
            imageView.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: arView.bottomAnchor)
        ])
    }

    private func setupInfoLabel() {
        infoLabel.textColor = .white
        infoLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        infoLabel.font = .systemFont(ofSize: 14)
        infoLabel.textAlignment = .center
        infoLabel.numberOfLines = 0
        infoLabel.layer.cornerRadius = 8
        infoLabel.clipsToBounds = true
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        setInfoText(nil)

        view.addSubview(infoLabel)

        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: sessionInfoView.bottomAnchor, constant: 10),
            infoLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            infoLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    private func setupTransparencyControls() {
        transparencySlider.minimumValue = 0
        transparencySlider.maximumValue = 1
        transparencySlider.value = 0.5
        transparencySlider.addTarget(self, action: #selector(transparencySliderChanged(_:)), for: .valueChanged)
        transparencySlider.translatesAutoresizingMaskIntoConstraints = false

        sliderLabel.text = "Transparency: 50%"
        sliderLabel.textColor = .white
        sliderLabel.font = .systemFont(ofSize: 12)
        sliderLabel.textAlignment = .center
        sliderLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(transparencySlider)
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
        channelButton.setTitle("Loading channels...", for: .normal)
        channelButton.setTitleColor(.white, for: .normal)
        channelButton.backgroundColor = .systemGray
        channelButton.layer.cornerRadius = 8
        channelButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        channelButton.isEnabled = false
        channelButton.translatesAutoresizingMaskIntoConstraints = false
        channelButton.addTarget(self, action: #selector(toggleChannelPicker), for: .touchUpInside)

        view.addSubview(channelButton)
    }

    private func setupMainToggleButton() {
        button.setTitle("Hide", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 8
        button.titleLabel?.font = .boldSystemFont(ofSize: 16)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(handleButtonTap), for: .touchUpInside)

        view.addSubview(button)

        applyConstraints()
    }

    private func applyConstraints() {
        NSLayoutConstraint.activate([

            // Transparency slider
            transparencySlider.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            transparencySlider.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            transparencySlider.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),

            sliderLabel.centerXAnchor.constraint(equalTo: transparencySlider.centerXAnchor),
            sliderLabel.bottomAnchor.constraint(equalTo: transparencySlider.topAnchor, constant: -5),

            // Channel button
            channelButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            channelButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            channelButton.bottomAnchor.constraint(equalTo: sliderLabel.topAnchor, constant: -10),
            channelButton.heightAnchor.constraint(equalToConstant: 44),

            // Channel picker
            channelPicker.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            channelPicker.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            channelPicker.bottomAnchor.constraint(equalTo: channelButton.topAnchor, constant: -5),
            channelPicker.heightAnchor.constraint(equalToConstant: 120),

            // Show/Hide button
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            button.widthAnchor.constraint(equalToConstant: 180),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    // MARK: - ARSession Delegate

    override func session(_ session: ARSession, didUpdate frame: ARFrame) {
        super.session(session, didUpdate: frame)

        guard let device else {
            assertionFailure("Metal device unavailable.")
            return
        }
        guard let manager else { return }

        loadChannelsIfNeeded(using: manager)

        guard !imageView.isHidden,
              let result = manager.latestConfidence(for: channels[selectedChannelIndex])
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

    // MARK: - Processing Helpers

    private func loadChannelsIfNeeded(using manager: SceneSegmentationManager) {
        guard !areChannelsLoaded else { return }

        channels = SemanticsChannelName.allChannels

        DispatchQueue.main.async {
            self.applyChannelNames(self.channels)
        }

        setInfoText(nil)
        areChannelsLoaded = true
    }

    // MARK: - Channel Handling

    private func applyChannelNames(_ channelNameEnums: [SemanticsChannelName]) {
        channelButton.isEnabled = true
        channelButton.backgroundColor = .systemBlue

        // Set default selection (try to find "ground" or use first channel)
        if let groundIndex = channels.firstIndex(where: { $0 == .ground }) {
            selectedChannelIndex = groundIndex
        } else {
            selectedChannelIndex = 0
        }

        // Update button title
        let selectedChannelName = formatChannelName(channels[selectedChannelIndex])
        channelButton.setTitle("Semantic Channel: \(selectedChannelName) ▼", for: .normal)

        channelPicker.reloadAllComponents()
        channelPicker.selectRow(selectedChannelIndex, inComponent: 0, animated: false)
    }
}

// MARK: - UIPickerView DataSource & Delegate

extension SceneSegmentationViewController: UIPickerViewDataSource, UIPickerViewDelegate {
    /// Formats a channel enum to a displayable string
    private func formatChannelName(_ channel: SemanticsChannelName) -> String {
        return channel.description
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    // MARK: - UIPickerViewDataSource
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        channels.count
    }

    func pickerView(_ pickerView: UIPickerView,
                    titleForRow row: Int,
                    forComponent component: Int) -> String? {
        formatChannelName(channels[row])
    }

    func pickerView(_ pickerView: UIPickerView,
                    viewForRow row: Int,
                    forComponent component: Int,
                    reusing view: UIView?) -> UIView {
        let label: UILabel
        if let reusedLabel = view as? UILabel {
            label = reusedLabel
        } else {
            label = UILabel()
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 17)
        }

        label.text = formatChannelName(channels[row])
        label.textColor = .white

        return label
    }

    func pickerView(_ pickerView: UIPickerView,
                    didSelectRow row: Int,
                    inComponent component: Int) {
        guard row < channels.count else { return }

        selectedChannelIndex = row
        let selectedChannelName = formatChannelName(channels[row])
        channelButton.setTitle("Semantic Channel: \(selectedChannelName) ▼", for: .normal)
        print("Selected semantic channel: \(selectedChannelName) (enum: \(channels[row]), index: \(row))")
    }
}

// MARK: - UI Actions

extension SceneSegmentationViewController {
    private func setInfoText(_ text: String?) {
        infoLabel.text = text
        infoLabel.isHidden = (text?.isEmpty ?? true)
    }

    @objc private func transparencySliderChanged(_ sender: UISlider) {
        let percentage = Int(sender.value * 100)
        sliderLabel.text = "Transparency: \(percentage)%"
        imageView.opacity = sender.value
    }

    @objc private func handleButtonTap() {
        imageView.reset()
        imageView.isHidden.toggle()
        button.setTitle(imageView.isHidden ? "Show" : "Hide", for: .normal)
    }

    @objc private func toggleChannelPicker() {
        guard areChannelsLoaded else { return }

        isChannelPickerVisible.toggle()

        UIView.animate(withDuration: 0.3) {
            self.channelPicker.isHidden = !self.isChannelPickerVisible
            self.channelButton.alpha = self.isChannelPickerVisible ? 0.7 : 1.0
        }

        let arrow = isChannelPickerVisible ? "▲" : "▼"
        let channel = formatChannelName(channels[selectedChannelIndex])
        channelButton.setTitle("Semantic Channel: \(channel) \(arrow)", for: .normal)
    }
}
