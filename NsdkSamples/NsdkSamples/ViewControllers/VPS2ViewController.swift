// Copyright 2026 Niantic Spatial.

import Combine
import CoreLocation
import MapKit
import NSDK
import RealityKit
import UIKit

final class VPS2ViewController: UIViewController {

    var anchorPayload: String = "<PUT_ANCHOR_PAYLOAD_HERE>"

    private let bottomChromeInset: CGFloat = 16

    private let arManager: ARManager

    private var vps2Session: NSDKVps2Session?
    private var viewModel: VPS2ViewModel!

    private var meshDownloader: NSDKMeshDownloader?
    private var retryHelper: AuthRetryHelper!
    private var meshDownloadTask: Task<Void, Never>?

    private var anchors: [NSDKVpsAnchorId: AnchorEntity] = [:]
    private let coarseMarker = Entity()
    private var refinedMarker = Entity()
    private var poiArrow: AnchorEntity?

    private let statusOverlay = ARStatusOverlay()
    private let infoStatusContainer = UIView()
    private let infoLabel = UILabel()
    private let mapView = MKMapView()
    private let userLocationIndicator = GeolocationIndicatorView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
    private let poiLocationIndicator = GeolocationIndicatorView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
    private let localizeButton = UIButton(type: .system)

    private var cancellables = Set<AnyCancellable>()

    init(arManager: ARManager) {
        self.arManager = arManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        meshDownloadTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "VPS2 Localization"
        view.backgroundColor = .darkGray

        arManager.nsdkView.setup(in: view)
        setupInfoLabel()
        setupMap()
        setupLocalizeButton()
        statusOverlay.setup(in: view)

        retryHelper = AuthRetryHelper(session: arManager.nsdkSession)

        let session = arManager.nsdkSession.acquireVps2Session()
        vps2Session = session
        let config = NSDKVps2Session.Configuration(
            initialVpsRequestsPerSecond: 1,
            continuousVpsRequestsPerSecond: 0.2
        )
        do {
            try session.configure(with: config)
        } catch {
            print("[VPS2ViewController] Failed to configure VPS2 session: \(error)")
        }

        coarseMarker.addChild(makeSphereEntity(radius: 5, color: .red, alpha: 0.5))
        refinedMarker.addChild(makeCubeEntity(size: 1.0, color: .red))

        viewModel = VPS2ViewModel(session: session, frameState: arManager.frameState)

        bindViewModel()
        bindFrameStateOverlay()
        bindAnchorSceneGraph()
        bindPoiArrow()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        let payloadSet = !anchorPayload.contains("ANCHOR_PAYLOAD") && !anchorPayload.isEmpty
        if payloadSet {
            vps2Session?.start()
        }

        arManager.startSession()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startPOIMeshDownload()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Stop the session before removing anchors so the NSDK frame loop
        // cannot re-add or update anchor entities after we clear them.
        vps2Session?.stop()

        for (_, node) in anchors {
            node.removeFromParent()
        }
        anchors.removeAll()
        poiArrow?.removeFromParent()
        poiArrow = nil

        coarseMarker.children.removeAll()
        refinedMarker.children.removeAll()

        meshDownloadTask?.cancel()
        meshDownloadTask = nil

        mapView.isHidden = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        arManager.stopSession()
        if isMovingFromParent {
            vps2Session = nil
        }
    }

    private func bindViewModel() {
        viewModel.$statusText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.infoLabel.text = text
            }
            .store(in: &cancellables)

        viewModel.$showMap
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                self?.mapView.isHidden = !show
                if show {
                    self?.createPoiArrowIfNeeded()
                    self?.refreshMapViewportIfNeeded(animated: false)
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            viewModel.$userMapCoordinate,
            viewModel.$userMapHeading,
            viewModel.$poiMapCoordinate,
            viewModel.$poiMapHeading
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] userCoord, userHeading, poiCoord, poiHeading in
            guard let self else { return }
            if let userCoord {
                self.updateIndicator(self.userLocationIndicator, to: userCoord, heading: userHeading)
            }
            if let poiCoord {
                self.updateIndicator(self.poiLocationIndicator, to: poiCoord, heading: poiHeading)
            }
            if userCoord != nil, poiCoord != nil {
                self.refreshMapViewportIfNeeded(animated: false)
            }
        }
        .store(in: &cancellables)
    }

    private func bindFrameStateOverlay() {
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

    private func bindAnchorSceneGraph() {
        viewModel.$anchorWorldTransforms
            .combineLatest(viewModel.$poiAnchorId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transforms, poiId in
                guard let self else { return }
                for (id, matrix) in transforms {
                    let anchor = self.getOrCreateSceneAnchor(anchorId: id)
                    anchor.transform = Transform(matrix: matrix)

                    if let poiId, id == poiId {
                        if anchor.children.isEmpty {
                            anchor.addChild(self.coarseMarker)
                            anchor.addChild(self.refinedMarker)
                        }
                        if let update = self.viewModel.anchorUpdatesById[id] {
                            self.applyMarkerVisibility(for: update)
                        }
                    }
                }
            }
            .store(in: &cancellables)

        viewModel.$anchorUpdatesById
            .combineLatest(viewModel.$poiAnchorId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updates, poiId in
                guard let self, let poiId, let update = updates[poiId] else { return }
                self.applyMarkerVisibility(for: update)
            }
            .store(in: &cancellables)
    }

    private func applyMarkerVisibility(for args: VpsAnchorUpdate) {
        switch args.trackingState {
        case .notTracked:
            coarseMarker.isEnabled = false
            refinedMarker.isEnabled = false
        case .limited:
            coarseMarker.isEnabled = true
            refinedMarker.isEnabled = false
            createPoiArrowIfNeeded()
        case .tracked:
            coarseMarker.isEnabled = false
            refinedMarker.isEnabled = true
        }
    }

    private func bindPoiArrow() {
        Publishers.CombineLatest3(
            arManager.frameState.$camera,
            viewModel.$anchorUpdatesById,
            viewModel.$poiAnchorId
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _ in
            self?.updatePoiArrowInWorld()
        }
        .store(in: &cancellables)
    }

    private func setupInfoLabel() {
        infoStatusContainer.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        infoStatusContainer.layer.cornerRadius = 10
        infoStatusContainer.clipsToBounds = true
        infoStatusContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoStatusContainer)

        infoLabel.textColor = .white
        infoLabel.font = .systemFont(ofSize: 12)
        infoLabel.numberOfLines = 0
        infoLabel.textAlignment = .center
        infoLabel.backgroundColor = .clear
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoStatusContainer.addSubview(infoLabel)

        NSLayoutConstraint.activate([
            infoStatusContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            infoStatusContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            infoStatusContainer.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -bottomChromeInset
            ),

            infoLabel.topAnchor.constraint(equalTo: infoStatusContainer.topAnchor, constant: 10),
            infoLabel.leadingAnchor.constraint(equalTo: infoStatusContainer.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(equalTo: infoStatusContainer.trailingAnchor, constant: -12),
            infoLabel.bottomAnchor.constraint(equalTo: infoStatusContainer.bottomAnchor, constant: -10),
        ])
    }

    private func setupMap() {
        mapView.layer.cornerRadius = 20
        mapView.isHidden = true
        mapView.clipsToBounds = true
        mapView.isZoomEnabled = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.isScrollEnabled = false
        mapView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapView)

        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            mapView.bottomAnchor.constraint(equalTo: infoStatusContainer.topAnchor, constant: -10),
            mapView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 1.0 / 3.0),
        ])

        userLocationIndicator.displaysHeading = true
        poiLocationIndicator.displaysHeading = false
        poiLocationIndicator.color = .red
        mapView.addSubview(userLocationIndicator)
        mapView.addSubview(poiLocationIndicator)
    }

    private func setupLocalizeButton() {
        localizeButton.setTitle("Localize Anchor", for: .normal)
        localizeButton.setTitleColor(.white, for: .normal)
        localizeButton.backgroundColor = .systemBlue
        localizeButton.layer.cornerRadius = 8
        localizeButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        localizeButton.translatesAutoresizingMaskIntoConstraints = false
        localizeButton.addTarget(self, action: #selector(localizeButtonTap), for: .touchUpInside)
        view.addSubview(localizeButton)

        NSLayoutConstraint.activate([
            localizeButton.bottomAnchor.constraint(equalTo: infoStatusContainer.topAnchor, constant: -10),
            localizeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            localizeButton.widthAnchor.constraint(equalToConstant: 200),
            localizeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        let payloadSet = !anchorPayload.contains("ANCHOR_PAYLOAD") && !anchorPayload.isEmpty
        if payloadSet {
            infoLabel.text = "Not localized."
            localizeButton.isHidden = false
        } else {
            infoLabel.text = "Anchor payload must be set before attempting to localize."
            localizeButton.isHidden = true
        }
    }

    @objc private func localizeButtonTap() {
        infoLabel.text = "Localizing..."
        Task { @MainActor in
            do {
                try await retryHelper.withRetry { [weak self] in
                    guard let self, let session = self.vps2Session else { return }
                    let id = try session.trackAnchor(payload: self.anchorPayload)
                    self.viewModel.poiAnchorId = id
                }
            } catch {
                print("Failed to track anchor. Error: \(String(describing: error))")
            }
        }
        localizeButton.isHidden = true
    }

    private func startPOIMeshDownload() {
        if meshDownloader == nil {
            meshDownloader = arManager.nsdkSession.acquireMeshDownloader()
        }
        guard let meshDownloader else { return }

        meshDownloadTask?.cancel()
        let payload = anchorPayload
        meshDownloadTask = Task { [weak self, meshDownloader] in
            guard let self else { return }
            do {
                try await self.retryHelper.withRetry {
                    let meshResults = try await meshDownloader.requestLocationMesh(
                        payload: payload,
                        getTexture: true
                    )
                    try Task.checkCancellation()
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.refinedMarker.children.removeAll()
                        self.loadMesh(meshResults, to: self.refinedMarker)
                    }
                }
            } catch is CancellationError {
            } catch {
                print("Failed to download mesh: \(error)")
            }
        }
    }
}

extension VPS2ViewController {
    @discardableResult
    private func getOrCreateSceneAnchor(anchorId: NSDKVpsAnchorId) -> AnchorEntity {
        if let existing = anchors[anchorId] { return existing }

        let anchor = AnchorEntity(world: .zero)
        anchor.name = String(describing: anchorId)
        arManager.nsdkView.scene.addAnchor(anchor)
        anchors[anchorId] = anchor
        return anchor
    }

    private func loadMesh(_ meshResults: MeshDownloaderResults, to parent: Entity) {
        for result in meshResults.results {
            var material = SimpleMaterial()

            if let image = UIImage(data: Data(bytes: result.imageData.data, count: Int(result.imageData.dataSize))),
               let cgImage = image.cgImage {
                do {
                    let texture = try TextureResource(image: cgImage, options: .init(semantic: .color))
                    material.color = .init(texture: .init(texture))
                    material.roughness = .init(floatLiteral: 0.5)
                    material.metallic = .init(floatLiteral: 0.0)
                } catch {
                    material.color = .init(tint: .blue.withAlphaComponent(0.75))
                }
            } else {
                material.color = .init(tint: .blue.withAlphaComponent(0.75))
            }

            guard let meshResource = result.meshData.toMeshResource() else { continue }

            let modelEntity = ModelEntity(mesh: meshResource, materials: [material])
            modelEntity.transform = Transform(matrix: result.transform)
            parent.addChild(modelEntity)
        }
    }

    private func createPoiArrowIfNeeded() {
        guard poiArrow == nil else { return }

        let arrowModel = makeArrowEntity()
        arrowModel.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])

        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(arrowModel)

        arManager.nsdkView.scene.addAnchor(anchor)
        poiArrow = anchor
    }

    private func updatePoiArrowInWorld() {
        guard
            let poiId = viewModel.poiAnchorId,
            let poiAnchor = anchors[poiId],
            let poiArrow = poiArrow,
            let camera = arManager.frameState.camera
        else { return }

        let lastPoiUpdate = viewModel.anchorUpdatesById[poiId]
        guard case .limited = lastPoiUpdate?.trackingState else {
            poiArrow.isEnabled = false
            return
        }

        let cameraTransform = camera.transform

        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        let cameraForward = -SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        )

        let distance: Float = 0.5
        let arrowWorldPosition = cameraPosition + cameraForward * distance
        poiArrow.position = arrowWorldPosition

        let poiWorldPosition = poiAnchor.position(relativeTo: nil)
        let dir = simd_normalize(poiWorldPosition - arrowWorldPosition)
        let forward = SIMD3<Float>(0, 0, -1)
        let q = simd_quatf(from: forward, to: dir)
        poiArrow.orientation = q

        var toPoi = poiWorldPosition - cameraPosition
        let isNearPoi = simd_length_squared(toPoi) < 5.0
        toPoi = simd_normalize(toPoi)

        let angleDegrees: Float = 40.0
        let cosThreshold = cos(angleDegrees * (.pi / 180.0))
        let dot = simd_dot(cameraForward, toPoi)
        let isLookingAtPoi = dot >= cosThreshold

        poiArrow.isEnabled = !isLookingAtPoi || !isNearPoi
    }

    private func makeArrowEntity(
        shaftLength: Float = 0.20,
        shaftRadius: Float = 0.006,
        headLength: Float = 0.06,
        headRadius: Float = 0.02,
        color: UIColor = .red
    ) -> ModelEntity {
        let material = SimpleMaterial(color: color, isMetallic: false)
        let shaftMesh = MeshResource.generateCylinder(height: shaftLength, radius: shaftRadius)
        let shaft = ModelEntity(mesh: shaftMesh, materials: [material])
        shaft.position = [0, shaftLength * 0.5, 0]

        let headMesh = MeshResource.generateCone(height: headLength, radius: headRadius)
        let head = ModelEntity(mesh: headMesh, materials: [material])
        head.position = [0, shaftLength + headLength * 0.5, 0]

        let arrow = ModelEntity()
        arrow.addChild(shaft)
        arrow.addChild(head)
        return arrow
    }

    private func makeCubeEntity(
        size: Float = 0.1,
        color: UIColor = .systemRed
    ) -> ModelEntity {
        let material = SimpleMaterial(color: color, isMetallic: false)
        let mesh = MeshResource.generateBox(size: size)
        return ModelEntity(mesh: mesh, materials: [material])
    }

    private func makeSphereEntity(
        radius: Float,
        color: UIColor,
        alpha: CGFloat
    ) -> ModelEntity {
        var material = SimpleMaterial()
        material.color = .init(tint: color.withAlphaComponent(alpha))
        material.roughness = .init(floatLiteral: 1.0)
        material.metallic = .init(floatLiteral: 0.0)
        let mesh = MeshResource.generateSphere(radius: radius)
        return ModelEntity(mesh: mesh, materials: [material])
    }
}

extension VPS2ViewController {
    private func updateIndicator(
        _ indicator: GeolocationIndicatorView,
        to coordinate: CLLocationCoordinate2D,
        heading: CGFloat? = nil
    ) {
        indicator.center = mapView.convert(coordinate, toPointTo: mapView)
        if let heading {
            indicator.heading = heading
        }
    }

    private func refreshMapViewportIfNeeded(animated: Bool = true) {
        guard let poi = viewModel.poiMapCoordinate, let user = viewModel.userMapCoordinate else { return }

        let p0 = MKMapPoint(poi)
        let p1 = MKMapPoint(user)

        var needed = MKMapRect.null
        needed = needed.union(MKMapRect(origin: p0, size: .init(width: 0, height: 0)))
        needed = needed.union(MKMapRect(origin: p1, size: .init(width: 0, height: 0)))
        needed = needed.expandedToMinimumSize(200)

        let current = mapView.visibleMapRect
        let visibilityInsetFraction: Double = 0.08
        let insetX = current.size.width * visibilityInsetFraction
        let insetY = current.size.height * visibilityInsetFraction
        let comfortableVisible = current.insetBy(dx: insetX, dy: insetY)

        let bothVisible = comfortableVisible.contains(p0) && comfortableVisible.contains(p1)
        let currentArea = max(current.size.width * current.size.height, 1)
        let neededArea = max(needed.size.width * needed.size.height, 1)
        let zoomOutFactor = currentArea / neededArea
        let tooZoomedOut = zoomOutFactor > 4.0

        guard !bothVisible || tooZoomedOut else { return }

        let edgePadding = UIEdgeInsets(top: 80, left: 80, bottom: 80, right: 80)
        mapView.setVisibleMapRect(needed, edgePadding: edgePadding, animated: animated)
    }
}

private extension MKMapRect {
    func expandedToMinimumSize(_ minSize: Double) -> MKMapRect {
        var r = self

        if r.size.width < minSize {
            let delta = (minSize - r.size.width) * 0.5
            r.origin.x -= delta
            r.size.width = minSize
        }

        if r.size.height < minSize {
            let delta = (minSize - r.size.height) * 0.5
            r.origin.y -= delta
            r.size.height = minSize
        }

        return r
    }
}
