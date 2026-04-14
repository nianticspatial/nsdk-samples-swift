// Copyright 2026 Niantic Spatial.

import UIKit
import ARKit
import RealityKit
import NSDK
import Combine

class SavedMapCardView: UIView {
    var fileName: String?
    var image: String?
}

final class DeviceMappingViewController: UIViewController {

    // MARK: - AR

    private let arManager: ARManager

    // MARK: - SDK Sessions (owned here; lifetime tied to this VC)

    private var mappingSession: NSDKDeviceMappingSession!
    private var mapStorage: NSDKMapStorage!
    private var vps2Session: NSDKVps2Session!

    // MARK: - ViewModel

    private var viewModel: DeviceMappingViewModel!

    // MARK: - Local UI State

    private var isMapping = false
    private var isVpsRunning = false

    // MARK: - UI

    private let mappingButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let loadButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let statusOverlay = ARStatusOverlay()
    private let helpOverlay = HelpOverlayView(helpText: DeviceMappingViewController.helpText)

    private lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.isHidden = true
        return sv
    }()

    private lazy var cardStackView: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.spacing = 12
        sv.alignment = .fill
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    // MARK: - RealityKit State

    private var mapAnchorEntity: AnchorEntity?
    private var visualizedEntities: [Entity] = []
    private var cachedPointMaterial: UnlitMaterial?
    private let maxDisplayedPoints = 3000

    // MARK: - Combine

    /// Torn down and rebuilt whenever the ViewModel is recreated (e.g. after loading a map).
    private var vmCancellables = Set<AnyCancellable>()
    /// Persistent subscriptions that don't depend on the ViewModel (AR status overlay, etc.).
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
        title = "Device Mapping"
        view.backgroundColor = .black

        arManager.nsdkView.setup(in: view)
        setupControls()
        setupScrollView()
        statusOverlay.setup(in: view)
        helpOverlay.setup(in: view, anchoredBelow: statusOverlay.bottomAnchor, navigationItem: navigationItem)

        setupSessions()
        setupViewModel()
        bindPersistentSubscriptions()
        checkSavedMapsAvailable()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        arManager.startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopAllSessions()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        arManager.stopSession()
    }

    // MARK: - Help

    private static let helpText =
        "Device Mapping Sample Help\n\n" +
        "This sample lets you anchor content to the world by scanning the local area and " +
        "saving a device map. These maps are saved to the device and can be shared with others.\n\n" +
        "TO USE:\n" +
        "Press \"Start Mapping\" to begin scanning the area around you. Once you're done, press " +
        "\"Stop Mapping\" to finalize the map. Then press \"Save Map\" to save the file.\n\n" +
        "To view existing maps, press \"Load Map\" to view the list of maps saved on the device " +
        "and select one to localize to."

    // MARK: - Session Setup

    private func setupSessions() {
        let nsdkSession = arManager.nsdkSession

        mappingSession = nsdkSession.acquireDeviceMappingSession()
        mapStorage = nsdkSession.acquireMapStorage()
        vps2Session = nsdkSession.acquireVps2Session()

        var vpsConfig = NSDKVps2Session.Configuration()
        vpsConfig.deviceMapLocalizationEnabled = true
        vpsConfig.universalLocalizationEnabled = false
        vpsConfig.vpsMapLocalizationEnabled = false
        try? vps2Session.configure(with: vpsConfig)
    }

    /// Creates (or recreates) the ViewModel and rebinds its subscriptions.
    ///
    /// Call once on initial setup and again any time `mapStorage` contents change before
    /// the VM is created (e.g. immediately after `mapStorage.addMap(map:)` for a loaded
    /// map). The new VM bootstraps itself from whatever is already in storage.
    private func setupViewModel() {
        vmCancellables.removeAll()

        viewModel = DeviceMappingViewModel(
            mappingSession: mappingSession,
            mapStorage: mapStorage,
            vps2Session: vps2Session
        )

        // React to the root anchor becoming available → start VPS tracking.
        // Because @Published emits its current value on subscription, a non-nil
        // rootAnchorPayload set during init (loaded-map bootstrap) fires immediately.
        viewModel.$rootAnchorPayload
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] anchor in
                try? self?.vps2Session.trackAnchor(payload: anchor)
            }
            .store(in: &vmCancellables)

        // Rebuild point cloud whenever the VM delivers new points.
        viewModel.$points
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] points in
                guard let self, let transform = viewModel.anchorTransform,
                      !points.isEmpty else { return }
                visualizeMapPoints(points: points, anchorTransform: transform)
                statusLabel.text = "Localized — \(points.count) points"
                statusLabel.textColor = .green
                saveButton.isHidden = isMapping
            }
            .store(in: &vmCancellables)

        // Reposition the existing anchor entity each frame — no geometry rebuild.
        viewModel.$anchorTransform
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transform in
                self?.mapAnchorEntity?.transform = Transform(matrix: transform)
            }
            .store(in: &vmCancellables)
    }

    // MARK: - Persistent Bindings (set up once, unaffected by VM recreation)

    private func bindPersistentSubscriptions() {
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
}

// MARK: - Mapping Lifecycle

private extension DeviceMappingViewController {

    func startMapping() {
        mappingSession.start()
        mappingSession.startMapping()
        if !isVpsRunning {
            vps2Session.start()
            isVpsRunning = true
        }
        isMapping = true
        loadButton.isHidden = true
        saveButton.isHidden = true
        mappingButton.setTitle("Stop Mapping", for: .normal)
        statusLabel.text = "Running Device Mapping"
        statusLabel.textColor = .white
        clearVisualization()
    }

    func stopMapping() {
        mappingSession.stopMapping()
        mappingSession.stop()
        vps2Session.stop()
        isVpsRunning = false
        isMapping = false
        mappingButton.setTitle("Start Mapping", for: .normal)
        saveButton.isHidden = viewModel.points.isEmpty
        statusLabel.text = ""
    }

    func stopAllSessions() {
        if isMapping {
            stopMapping()
        } else if isVpsRunning {
            vps2Session.stop()
            isVpsRunning = false
        }
    }
}

// MARK: - Actions

extension DeviceMappingViewController {

    @objc private func handleToggleMappingTap() {
        if isMapping { stopMapping() } else { startMapping() }
    }

    @objc private func handleSaveTap() {
        saveButton.isEnabled = false
        statusLabel.text = "Preparing map…"
        statusLabel.textColor = .white

        // mapStorage.mapData() serializes the native map — run it off the main thread
        // to avoid blocking the AR session and dropping tracking.
        let storage = mapStorage!
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let buffer = storage.mapData()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                saveButton.isEnabled = true
                statusLabel.text = ""
                guard let buffer else {
                    print("[DeviceMappingViewController2] No map data available to save")
                    return
                }
                presentSaveDialog(buffer: buffer)
            }
        }
    }

    @objc private func handleLoadTap() {
        cardStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let maps = listSavedMaps()
        maps.forEach { cardStackView.addArrangedSubview(makeMapCard(fileName: $0)) }
        scrollView.isHidden = false
        statusLabel.text = "Found \(maps.count) map(s)"
        statusLabel.textColor = .white
    }

    private func loadMapFromDisk(fileName: String) {
        do {
            scrollView.isHidden = true

            // Stop VPS before touching map storage — clear() must not be called while VPS
            // is running, and calling start() on an already-running session causes a
            // double-registration assertion crash in the native map data store module.
            if isVpsRunning {
                vps2Session.stop()
                isVpsRunning = false
            }
            mapStorage.clear()

            let finalName = fileName.hasSuffix(".map") ? fileName : "\(fileName).map"
            let data = try Data(contentsOf: try appSupportDirectory().appendingPathComponent(finalName))
            try mapStorage.addMap(map: NSDKBuffer(data: data))

            // Recreate the VM so its init bootstraps rootAnchorPayload from the map we
            // just loaded. The $rootAnchorPayload subscription then fires immediately
            // and calls vps2Session.trackAnchor once VPS is started below.
            setupViewModel()
            vps2Session.start()
            isVpsRunning = true

            loadButton.isHidden = true
            statusLabel.text = "Tracking anchor for localization…"
            statusLabel.textColor = .orange
        } catch {
            print("[DeviceMappingViewController2] Failed to load map: \(error)")
        }
    }
}

// MARK: - Setup

private extension DeviceMappingViewController {

    func setupControls() {
        mappingButton.setTitle("Start Mapping", for: .normal)
        mappingButton.setTitleColor(.white, for: .normal)
        mappingButton.backgroundColor = .systemBlue
        mappingButton.layer.cornerRadius = 8
        mappingButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        mappingButton.translatesAutoresizingMaskIntoConstraints = false
        mappingButton.addTarget(self, action: #selector(handleToggleMappingTap), for: .touchUpInside)
        view.addSubview(mappingButton)

        saveButton.setTitle("Save Map", for: .normal)
        saveButton.setTitleColor(.white, for: .normal)
        saveButton.backgroundColor = .systemGreen
        saveButton.layer.cornerRadius = 8
        saveButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        saveButton.isHidden = true
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.addTarget(self, action: #selector(handleSaveTap), for: .touchUpInside)
        view.addSubview(saveButton)

        loadButton.setTitle("Load Map", for: .normal)
        loadButton.setTitleColor(.white, for: .normal)
        loadButton.backgroundColor = .systemPurple
        loadButton.layer.cornerRadius = 8
        loadButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        loadButton.translatesAutoresizingMaskIntoConstraints = false
        loadButton.addTarget(self, action: #selector(handleLoadTap), for: .touchUpInside)
        view.addSubview(loadButton)

        statusLabel.text = ""
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            mappingButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            mappingButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            mappingButton.widthAnchor.constraint(equalToConstant: 120),
            mappingButton.heightAnchor.constraint(equalToConstant: 44),

            // Save and Load occupy the same position on the left — only one is ever visible at a time.
            saveButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 140),
            saveButton.centerYAnchor.constraint(equalTo: mappingButton.centerYAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 120),
            saveButton.heightAnchor.constraint(equalToConstant: 44),

            loadButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 140),
            loadButton.centerYAnchor.constraint(equalTo: mappingButton.centerYAnchor),
            loadButton.widthAnchor.constraint(equalToConstant: 120),
            loadButton.heightAnchor.constraint(equalToConstant: 44),

            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: mappingButton.topAnchor, constant: -12),
        ])
    }

    func setupScrollView() {
        view.addSubview(scrollView)
        scrollView.addSubview(cardStackView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -20),

            cardStackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            cardStackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            cardStackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            cardStackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            cardStackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    func checkSavedMapsAvailable() {
        loadButton.isHidden = listSavedMaps().isEmpty
    }
}

// MARK: - Point Cloud Rendering

private extension DeviceMappingViewController {

    func visualizeMapPoints(points: [SIMD3<Float>], anchorTransform: simd_float4x4) {
        clearVisualization()
        guard !points.isEmpty else { return }

        let step = max(1, points.count / maxDisplayedPoints)
        let halfSize: Float = 0.0035

        let baseVerts: [SIMD3<Float>] = [
            [-halfSize, -halfSize,  halfSize], [ halfSize, -halfSize,  halfSize],
            [ halfSize,  halfSize,  halfSize], [-halfSize,  halfSize,  halfSize],
            [-halfSize, -halfSize, -halfSize], [ halfSize, -halfSize, -halfSize],
            [ halfSize,  halfSize, -halfSize], [-halfSize,  halfSize, -halfSize],
        ]
        let baseIdx: [UInt32] = [
            0,1,2, 0,2,3,  5,4,7, 5,7,6,
            3,2,6, 3,6,7,  4,5,1, 4,1,0,
            1,5,6, 1,6,2,  4,0,3, 4,3,7,
        ]

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var vertexOffset: UInt32 = 0

        for i in stride(from: 0, to: points.count, by: step) {
            guard positions.count / baseVerts.count < maxDisplayedPoints else { break }
            let center = points[i]
            positions.append(contentsOf: baseVerts.map { $0 + center })
            indices.append(contentsOf: baseIdx.map { $0 + vertexOffset })
            vertexOffset += UInt32(baseVerts.count)
        }

        var descriptor = MeshDescriptor(name: "mapCubes")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)

        guard let mesh = try? MeshResource.generate(from: [descriptor]) else {
            print("[DeviceMappingViewController2] Failed to generate mesh")
            return
        }

        if cachedPointMaterial == nil {
            cachedPointMaterial = UnlitMaterial(color: .init(red: 0.3, green: 0.8, blue: 0.0, alpha: 1.0))
        }

        let entity = ModelEntity(mesh: mesh, materials: [cachedPointMaterial!])
        let anchor = AnchorEntity()
        anchor.transform = Transform(matrix: anchorTransform)
        anchor.addChild(entity)

        arManager.nsdkView.scene.addAnchor(anchor)
        mapAnchorEntity = anchor
        visualizedEntities.append(anchor)
    }

    func clearVisualization() {
        for entity in visualizedEntities {
            if let anchor = entity as? AnchorEntity {
                arManager.nsdkView.scene.removeAnchor(anchor)
            } else {
                entity.removeFromParent()
            }
        }
        visualizedEntities.removeAll()
        mapAnchorEntity = nil
    }
}

// MARK: - Map Card UI

private extension DeviceMappingViewController {

    func makeMapCard(fileName: String) -> UIView {
        let card = SavedMapCardView()
        card.fileName = fileName
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 12
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        card.layer.shadowRadius = 4
        card.layer.shadowOpacity = 0.1
        card.isUserInteractionEnabled = true
        card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cardTapped(_:))))

        let nameLabel = UILabel()
        nameLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        nameLabel.text = fileName
        nameLabel.numberOfLines = 0

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.layer.cornerRadius = 8
        imageView.clipsToBounds = true
        imageView.backgroundColor = .systemGray6
        loadThumbnail(into: imageView, fileName: fileName)

        [nameLabel, imageView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: -12),

            imageView.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            imageView.widthAnchor.constraint(equalToConstant: 40),
            imageView.heightAnchor.constraint(equalToConstant: 80),
            imageView.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    @objc func cardTapped(_ gesture: UITapGestureRecognizer) {
        guard let card = gesture.view as? SavedMapCardView, let name = card.fileName else { return }
        loadMapFromDisk(fileName: name)
    }
}

// MARK: - Save Dialog

private extension DeviceMappingViewController {

    func presentSaveDialog(buffer: NSDKBuffer) {
        let alert = UIAlertController(title: "Save Map", message: "Enter a filename.", preferredStyle: .alert)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let defaultName = "Map-\(formatter.string(from: Date()))"

        alert.addTextField { tf in
            tf.text = defaultName
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }

        let cancel = UIAlertAction(title: "Cancel", style: .cancel)
        let save = UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self, let raw = alert?.textFields?.first?.text else { return }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            saveMapToDisk(buffer: buffer, fileName: name)
        }
        save.isEnabled = !defaultName.isEmpty

        NotificationCenter.default.addObserver(
            forName: UITextField.textDidChangeNotification,
            object: alert.textFields?.first,
            queue: .main
        ) { notification in
            let text = (notification.object as? UITextField)?.text ?? ""
            save.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        alert.addAction(cancel)
        alert.addAction(save)
        present(alert, animated: true)
    }

    func saveMapToDisk(buffer: NSDKBuffer, fileName: String) {
        let mapData = Data(bytes: buffer.data, count: Int(buffer.dataSize))
        let finalName = fileName.hasSuffix(".map") ? fileName : "\(fileName).map"
        // Capture the screenshot on the main thread before dispatching I/O.
        let screenshotData = captureScreenshotData()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let dir = try appSupportDirectory()
                try mapData.write(to: dir.appendingPathComponent(finalName))
                if let pngData = screenshotData {
                    try? pngData.write(to: dir.appendingPathComponent("\(fileName).png"))
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    saveButton.isHidden = true
                    loadButton.isHidden = false
                    statusLabel.text = "Map saved"
                    statusLabel.textColor = .green
                }
            } catch {
                print("[DeviceMappingViewController2] Save failed: \(error)")
            }
        }
    }
}

// MARK: - Disk Helpers

private extension DeviceMappingViewController {

    func appSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.nianticspatial.nsdk-swift"
        )
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func listSavedMaps() -> [String] {
        guard let dir = try? appSupportDirectory() else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        return urls.filter { $0.pathExtension == "map" }.map { $0.lastPathComponent }
    }

    func loadThumbnail(into imageView: UIImageView, fileName: String) {
        let baseName = fileName.hasSuffix(".map") ? String(fileName.dropLast(4)) : fileName
        guard let dir = try? appSupportDirectory() else { return }
        let url = dir.appendingPathComponent("\(baseName).png")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return }
        imageView.image = image
    }

    func captureScreenshotData() -> Data? {
        let maxHeight: CGFloat = 320
        var size = view.bounds.size
        if size.height > maxHeight {
            let scale = maxHeight / size.height
            size = CGSize(width: size.width * scale, height: maxHeight)
        }
        return UIGraphicsImageRenderer(size: size).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }.pngData()
    }
}
