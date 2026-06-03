// Copyright 2026 Niantic Spatial.

import UIKit
import Metal
import NSDK
import Combine

final class CaptureViewController: UIViewController {

    // MARK: - AR

    private let arManager: ARManager

    // MARK: - Session + ViewModel

    private var scanningSession: NSDKScanningSession!
    private var viewModel: CaptureViewModel!

    // MARK: - State

    private var isCapturing = false
    private var exportTask: Task<Void, Never>?

    // MARK: - UI

    private var visualizationView: TextureView!
    private let captureButton = UIButton(type: .system)
    private let progressView = UIProgressView()
    private let statusLabel = UILabel()
    private let statusOverlay = ARStatusOverlay()
    private let helpOverlay = HelpOverlayUIKitView(helpText: CaptureViewController.helpText)

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
        title = "Capture"
        view.backgroundColor = .black

        arManager.nsdkView.setup(in: view)
        setupVisualizationView()
        setupControls()
        statusOverlay.setup(in: view)
        helpOverlay.setup(in: view, anchoredBelow: statusOverlay.bottomAnchor, navigationItem: navigationItem)

        // Scanning session: acquire and configure.
        // Not started until the user taps "Start Capture" — unlike depth/semantics which
        // start immediately, scanning is an explicit user action.
        let session: NSDKScanningSession = arManager.nsdkSession.acquireScanningSession()
        var config = NSDKScanningSession.Configuration()
        config.enableRaycastVisualization = true
        config.enableVoxelVisualization = false
        config.generateDepthsIfLidarUnavailable = true
        do {
            try session.configure(with: config)
        } catch {
            print("[CaptureViewController2] Failed to configure scanning session: \(error)")
        }
        scanningSession = session

        // ViewModel subscribes to session.$latestRaycastBuffer internally.
        viewModel = CaptureViewModel(session: session)

        viewModel.$compositeTexture
            .receive(on: DispatchQueue.main)
            .sink { [weak self] texture in
                guard let self, let texture else { return }
                self.visualizationView.setTexture(copyFrom: texture)
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
        arManager.startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        exportTask?.cancel()
        exportTask = nil
        scanningSession.stop()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        arManager.stopSession()
    }

    // MARK: - Help

    private static let helpText =
        "Capture Sample Help\n\n" +
        "This sample creates and saves a recording that can later be used for NSDK Playback.\n\n" +
        "TO USE:\n" +
        "Press 'Start Capture' to start capturing. A simple visualization will indicate the parts " +
        "covered by the capture, with red stripes indicating the missed areas. After the capture " +
        "stops, the capture will automatically be exported to Niantic Spatial's recorder format " +
        "and you can use the result archive for NSDK Playback."

    // MARK: - UI Setup

    private func setupVisualizationView() {
        visualizationView = TextureView(
            frame: view.bounds,
            vertexShader: "scanningVertexShader",
            fragmentShader: "scanningFragmentShader"
        )
        visualizationView.isOpaque = true
        visualizationView.translatesAutoresizingMaskIntoConstraints = false
        visualizationView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        visualizationView.isHidden = true
        arManager.nsdkView.addSubview(visualizationView)

        NSLayoutConstraint.activate([
            visualizationView.leadingAnchor.constraint(equalTo: arManager.nsdkView.leadingAnchor),
            visualizationView.topAnchor.constraint(equalTo: arManager.nsdkView.topAnchor),
            visualizationView.trailingAnchor.constraint(equalTo: arManager.nsdkView.trailingAnchor),
            visualizationView.bottomAnchor.constraint(equalTo: arManager.nsdkView.bottomAnchor),
        ])
    }

    private func setupControls() {
        statusLabel.text = ""
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        captureButton.setTitle("Start Capture", for: .normal)
        captureButton.setTitleColor(.white, for: .normal)
        captureButton.backgroundColor = .systemBlue
        captureButton.layer.cornerRadius = 8
        captureButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.addTarget(self, action: #selector(handleCaptureButtonTap), for: .touchUpInside)
        view.addSubview(captureButton)

        progressView.progressTintColor = .white
        progressView.trackTintColor = .systemGray
        progressView.isHidden = true
        progressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressView)

        NSLayoutConstraint.activate([
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            captureButton.widthAnchor.constraint(equalToConstant: 200),
            captureButton.heightAnchor.constraint(equalToConstant: 44),

            progressView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            progressView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            progressView.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -16),
            progressView.heightAnchor.constraint(equalToConstant: 4),

            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: progressView.topAnchor, constant: -8),
        ])
    }
}

// MARK: - Actions

extension CaptureViewController {

    @objc private func handleCaptureButtonTap() {
        if isCapturing {
            stopCapture()
        } else {
            startCapture()
        }
    }

    private func startCapture() {
        isCapturing = true
        statusLabel.text = ""
        captureButton.setTitle("Stop Capture", for: .normal)
        visualizationView.isHidden = false
        scanningSession.start()
    }

    private func stopCapture() {
        isCapturing = false
        captureButton.setTitle("Saving...", for: .normal)
        captureButton.isEnabled = false
        visualizationView.isHidden = true
        visualizationView.reset()

        let scanningSession = scanningSession!
        let nsdkSession = arManager.nsdkSession
        let progressView = progressView

        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Save scan
            let saveInfo: NSDKScanningSession.SaveInfo
            do {
                saveInfo = try await scanningSession.saveCurrentScan(timeout: 20)
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.statusLabel.text = "Failed to save capture."
                    self?.finishCaptureFlow()
                }
                return
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                progressView.progress = 0
                progressView.isHidden = false
            }

            // Acquire exporter on main actor (it's @MainActor)
            let exporter = await MainActor.run { nsdkSession.acquireRecordingExporter() }

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                self?.statusLabel.text = "Archiving capture..."
            }

            var archivePath: String?
            do {
                archivePath = try await exporter.export(
                    scanDirPath: saveInfo.path,
                    scanId: saveInfo.scanId,
                    exportAsVideo: false,
                    progressCallback: { progress in
                        DispatchQueue.main.async {
                            progressView.setProgress(progress, animated: true)
                        }
                    }
                )
            } catch {
                if !Task.isCancelled {
                    print("[CaptureViewController] Archive failed: \(error)")
                }
            }

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                progressView.isHidden = true
                self?.finishCaptureFlow()
                if let archivePath {
                    self?.statusLabel.text = "Capture saved and archived."
                    self?.presentShareSheet(for: archivePath)
                } else {
                    self?.statusLabel.text = "Failed to archive capture."
                }
            }
        }
    }

    private func finishCaptureFlow() {
        scanningSession.stop()
        captureButton.setTitle("Start Capture", for: .normal)
        captureButton.isEnabled = true
    }

    private func presentShareSheet(for filePath: String) {
        guard FileManager.default.fileExists(atPath: filePath) else {
            statusLabel.text = "Archive file not found."
            return
        }
        let fileURL = URL(fileURLWithPath: filePath)
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(activityVC, animated: true)
    }
}
