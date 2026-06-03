// Copyright 2026 Niantic Spatial.

import UIKit
import RealityKit
import Metal
import NSDK
import Combine

final class MeshingViewController: UIViewController {

    // MARK: - AR

    private let arManager: ARManager

    // MARK: - Session + ViewModel

    private var meshingSession: NSDKMeshingSession?
    private var viewModel: MeshingViewModel!

    // MARK: - UI

    private var isMeshing = false

    private var meshChunks: [Int64: ModelEntity] = [:]
    private var meshAnchor: AnchorEntity!

    private let meshingButton = UIButton(type: .system)
    private let infoLabel = UILabel()
    private let helpOverlay = HelpOverlayUIKitView(helpText: MeshingViewController.helpText)

    // MARK: - Combine

    private var cancellables = Set<AnyCancellable>()

    init(arManager: ARManager) {
        self.arManager = arManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Meshing"
        view.backgroundColor = .darkGray

        arManager.nsdkView.setup(in: view)
        setupControls()
        helpOverlay.setup(in: view, anchoredBelow: view.safeAreaLayoutGuide.topAnchor, navigationItem: navigationItem)

        meshAnchor = AnchorEntity(world: .zero)
        arManager.nsdkView.scene.addAnchor(meshAnchor)

        let session = arManager.nsdkSession.acquireMeshingSession()
        meshingSession = session

        viewModel = MeshingViewModel(meshingSession: meshingSession!)

        viewModel.updatedMeshChunks
        .receive(on: DispatchQueue.main)
        .sink { [weak self] chunksToUpdate in
            guard let self else { return }

            for (id, entity) in chunksToUpdate {
                self.renderMeshChunk(id: id, entity: entity)
            }

            // Update info text
            self.infoLabel.text = "Total mesh chunks: \(meshChunks.count)"
        }
        .store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        arManager.startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        stopMeshing()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        arManager.stopSession()

        meshingSession = nil

        meshChunks.removeAll()

        viewModel.cleanup()

        meshAnchor.removeFromParent()

        meshAnchor = nil
    }

    // MARK: - Help

    private static let helpText =
        "Meshing Sample Help\n\n" +
        "This sample creates a 3D mesh of the environment in front of your device camera.\n\n" +
        "TO USE:\n" +
        "Press the \"Start Meshing\" button and move the camera around. A mesh is dynamically " +
        "created and rendered. The mesh is not persistent — to restart, press \"Stop Meshing\" " +
        "and the process will restart."

    private func setupControls() {
        meshingButton.setTitle("Start Meshing", for: .normal)
        meshingButton.setTitleColor(.white, for: .normal)
        meshingButton.backgroundColor = .systemBlue
        meshingButton.layer.cornerRadius = 8
        meshingButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        meshingButton.translatesAutoresizingMaskIntoConstraints = false
        meshingButton.addTarget(self, action: #selector(handleToggleMeshingTap), for: .touchUpInside)
        view.addSubview(meshingButton)

        // Info label
        infoLabel.text = "Ready to begin Meshing"
        infoLabel.textColor = .white
        infoLabel.font = .systemFont(ofSize: 12)
        infoLabel.numberOfLines = 0
        infoLabel.textAlignment = .center
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)
        NSLayoutConstraint.activate([
            meshingButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            meshingButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            meshingButton.widthAnchor.constraint(equalToConstant: 180),
            meshingButton.heightAnchor.constraint(equalToConstant: 44),

            infoLabel.centerXAnchor.constraint(equalTo: meshingButton.centerXAnchor),
            infoLabel.bottomAnchor.constraint(equalTo: meshingButton.topAnchor, constant: -5),
            infoLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
    }

    private func startMeshing() {
        isMeshing = true

        var config = NSDKMeshingSession.Configuration()
        config.fuseKeyframesOnly = true

        do {
            clearMeshChunks()
            try meshingSession?.configure(with: config)
            meshingSession?.start()
        } catch {
            print("Unable to start meshing")
        }

        meshingButton.setTitle("Stop Meshing", for: .normal)
        infoLabel.text = "Meshing Started"
    }

    private func stopMeshing() {
        isMeshing = false
        meshingSession?.stop()
        meshingButton.setTitle("Start Meshing", for: .normal)
        infoLabel.text = "Meshing Stopped"
    }

    private func renderMeshChunk(id: Int64, entity: ModelEntity?) {
        if let existingEntity = meshChunks[id] {
            existingEntity.removeFromParent()
        }

        if entity == nil {
            meshChunks.removeValue(forKey: id)
            return
        }

        meshChunks[id] = entity
        meshAnchor.addChild(entity!)
    }

    private func clearMeshChunks() {
        for id in meshChunks.keys {
            if let existingEntity = meshChunks[id] {
                existingEntity.removeFromParent()
            }
        }

        meshChunks.removeAll()
    }
}

// MARK: - Actions

extension MeshingViewController {

    @objc private func handleToggleMeshingTap() {
        guard let meshingSession else {
            assertionFailure("An active NSDK session is required.")
            return
        }

        isMeshing ? stopMeshing() : startMeshing()
    }
}
