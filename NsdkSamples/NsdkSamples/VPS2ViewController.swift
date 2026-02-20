import ARKit
import UIKit
import MapKit
import RealityKit
import SwiftyNsdk

final class VPS2ViewController: BaseARViewController {
    // Replace this with a real payload string
    internal var anchorPayload: String = "" //<-- PUT_ANCHOR_PAYLOAD_HERE

    // Nsdk components and managers
    private var manager: Vps2Manager?
    private var meshDownloader: NsdkMeshDownloader?
    private var retryHelper: AuthRetryHelper!

    // Tasks
    private var locationUpdateTask: Task<Void, Never>?
    private var meshDownloadTask: Task<Void, Never>?

    // Boundle vps anchors with scene anchors
    private var anchors: [NsdkVpsAnchorId: AnchorEntity] = [:]
    private let coarseMarker = Entity()
    private var refinedMarker = Entity()

    // UI components
    private var localizeButton = UIButton()
    private let mapView = MKMapView()
    private var userLocationIndicator = GeolocationIndicatorView.init(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
    private var poiLocationIndicator = GeolocationIndicatorView.init(frame: CGRect(x: 0, y: 0, width: 60, height: 60))

    // Helpers
    private var poiAnchorId: NsdkVpsAnchorId?
    private var lastPoiCoordinate: CLLocationCoordinate2D?
    private var lastUserCoordinate: CLLocationCoordinate2D?
    private var poiArrow: AnchorEntity?
    private var lastPoiAnchorUpdate: VpsAnchorUpdate?
    private var currTransformer: Vps2Transformer?

    override func setupUI() {
        super.setupUI()
        self.title = "VPS2 Localization"
        helpLabel.text = "Localize to a Site \n\n" +
        "TO USE:\n Make sure you've been logged in and have a valid Anchor payload to localize to.\n" +
        "Tap the Localize Anchor Button. \n\n "

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
            mapView.bottomAnchor.constraint(equalTo: sampleInfoLabel.topAnchor, constant: -10),
            mapView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 1.0 / 3.0)
        ])

        userLocationIndicator.displaysHeading = true
        mapView.addSubview(userLocationIndicator)

        poiLocationIndicator.displaysHeading = false
        poiLocationIndicator.color = .red
        mapView.addSubview(poiLocationIndicator)
        localizeButton.setTitle("Localize Anchor", for: .normal)
        localizeButton.setTitleColor(.white, for: .normal)
        localizeButton.backgroundColor = .systemBlue
        localizeButton.layer.cornerRadius = 8
        localizeButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        localizeButton.addTarget(self, action: #selector(localizeButtonTap), for: .touchUpInside)
        localizeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(localizeButton)

        NSLayoutConstraint.activate([
            localizeButton.bottomAnchor.constraint(equalTo: sampleInfoLabel.topAnchor, constant: -10),
            localizeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            localizeButton.widthAnchor.constraint(equalToConstant: 200),
            localizeButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let nsdkManager = nsdkManager else { return }
        manager = Vps2Manager(nsdk: nsdkManager.session)
        manager?.delegate = self
        retryHelper = AuthRetryHelper(session: nsdkManager.session)

        // Prepare the POI markers
        coarseMarker.addChild(makeCubeEntity(size: 1.0, color: .red))
        refinedMarker.addChild(makeCubeEntity(size: 1.0, color: .red))
    }

    deinit {
        meshDownloadTask?.cancel()
        locationUpdateTask?.cancel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Only proceed if view is loaded and manager is initialized
        guard isViewLoaded, let manager = manager else { return }

        updateInfoLabel(text: "Not localized.")

        // Start the service
        manager.start()

        // Enable the localization button if there's ananchor set.
        localizeButton.isHidden = anchorPayload.isEmpty
    }

    override func viewDidAppear(_ animated: Bool) {
        arView.isHidden = false

        super.viewDidAppear(animated)

        // Delay mesh download start to ensure AR system is ready
        // This prevents race conditions where mesh downloader tries to use session before it's initialized
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startPOIMeshDownload()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Clean up all anchors
        for (_, node) in anchors {
            node.removeFromParent()
        }
        anchors.removeAll()
        poiArrow?.removeFromParent()

        // Stop the manager
        manager?.stop()

        // Cancel tasks
        meshDownloadTask?.cancel()
        meshDownloadTask = nil
        locationUpdateTask?.cancel()
        locationUpdateTask = nil

        // Hide the map UI
        mapView.isHidden = true

        // Reset transient state
        poiAnchorId = nil
        lastPoiCoordinate = nil
        lastUserCoordinate = nil
    }

    // Initiates tracking the preset POI anchor
    @objc private func localizeButtonTap() {
        Task { @MainActor in
            do {
                try await retryHelper.withRetry {
                    let id = try manager?.trackAnchor(anchorPayload: anchorPayload)
                    poiAnchorId = id
                }
            } catch {
                print("Failed to track anchor. Error: \(String(describing: error))")
            }
        }
        localizeButton.isHidden = true
    }

    private func startPOIMeshDownload() {
        guard let nsdkManager, !anchorPayload.isEmpty else { return }

         if meshDownloader == nil {
           meshDownloader = nsdkManager.session.createMeshDownloader()
        }

        guard let meshDownloader = meshDownloader else {
            return
        }

        meshDownloadTask?.cancel()
        meshDownloadTask = Task { [weak self, anchorPayload, meshDownloader] in
            do {
                try await retryHelper.withRetry {
                    let meshResults = try await meshDownloader.requestLocationMesh(
                        payload: anchorPayload,
                        getTexture: true
                    )
                    try Task.checkCancellation()
                    await MainActor.run {
                        guard let self else { return }

                        // Remove previously present objects
                        self.refinedMarker.children.removeAll()

                        // Load the mesh for the marker
                        self.loadMesh(meshResults, to: self.refinedMarker)
                    }
                }
            } catch is CancellationError {
                // expected
            } catch {
                print("Failed to download mesh: \(error)")
            }
        }
    }

    override func session(_ session: ARSession, didUpdate frame: ARFrame) {
        super.session(session, didUpdate: frame)

        currTransformer = manager?.latestLocalizedTransformer()
        updateUserLocationOnMap()
        updatePoiLocationOnMap()
        updatePoiArrowInWorld()
        refreshMapViewportIfNeeded(animated: false)
        updateInfoLabel()
    }
}

// MARK: - Vps2ManagerDelegate
extension VPS2ViewController: Vps2ManagerDelegate {
    /// Computes the geographic location and heading corresponding to an AR pose.
    ///
    /// This method converts the provided AR-space transform into a geolocation using the
    /// most recent localized VPS2 transformer. If the VPS2 service is not currently
    /// localized, the method returns `nil`.
    ///
    /// - Parameter transform: The pose in the device’s AR coordinate space.
    /// - Returns: A tuple containing the geographic coordinate and heading derived from
    ///   the pose, or `nil` if localization is unavailable.
    func getLocation(for transform: simd_float4x4) -> (location: CLLocationCoordinate2D, heading: Double)?
    {
        guard
            let manager,
            let transformer = currTransformer,
            transformer.trackingState != .unavailable
        else {
            return nil
        }

        guard let geo = manager.geolocation(transformer: transformer, pose: transform) else {
            return nil
        }

        let coordinate = CLLocationCoordinate2D(
            latitude: geo.geolocationData.latitude,
            longitude: geo.geolocationData.longitude
        )

        return (location: coordinate, heading: geo.geolocationData.heading)
    }

    func vps2Manager(_ manager: Vps2Manager, didChangeLocalizationStatus localized: Bool) {
        // Show the map when localized
        mapView.isHidden = !localized

        // Create the arrow pointing to the POI
        createPoiArrowIfNeeded()
    }

    // Callback for anchor pose updates.
    func vps2Manager(_ manager: Vps2Manager, didUpdateAnchor id: NsdkVpsAnchorId, args: VpsAnchorUpdate) {
        guard let transform = args.anchorToLocalTransform else { return }

        // Update anchor pose
        let anchor = getOrCreateSceneAnchor(anchorId: id)
        anchor.transform = Transform(matrix: transform)

        // Anchor is the main POI
        if let poiAnchorId, id == poiAnchorId {
            // Make sure the markers are added to the anchor
            if anchor.children.isEmpty {
                anchor.addChild(coarseMarker)
                anchor.addChild(refinedMarker)
            }

            // Indicate the level of tracking precision
            lastPoiAnchorUpdate = args
            switch args.trackingState {
            case .notTracked:
                // Disable markers
                coarseMarker.isEnabled = false
                refinedMarker.isEnabled = false

            case .limited:
                // Show coarse marker (cube)
                coarseMarker.isEnabled = true
                refinedMarker.isEnabled = false
                createPoiArrowIfNeeded()

            case .tracked:
                // Show precise marker (mesh)
                coarseMarker.isEnabled = false
                refinedMarker.isEnabled = true
            }
        }
    }

    /// Monitor network errors.
    func vps2Manager(_ manager: Vps2Manager, didReceiveNetworkRequestRecords records: [Vps2NetworkRequestRecord]) {
        for record in records {
            if record.status == .failed || record.error != .none {
                print("""
                    VPS2 network request failed:
                      id: \(record.identifier)
                      type: \(record.type)
                      status: \(record.status)
                      error: \(record.error)
                    """)
            }
        }
    }
    
    func updateInfoLabel() {
        let stateText: String
        if let transformer = currTransformer {
            stateText = String(describing: transformer.trackingState)
        } else {
            stateText = "Unavailable"
        }
        
        var updateText: String
        if poiAnchorId != nil {
            if let anchorUpdate = lastPoiAnchorUpdate {
                updateText = String(describing: anchorUpdate.trackingState)
                if anchorUpdate.trackingStateReason != VpsAnchorUpdate.AnchorTrackingStateReason.none {
                    updateText += " (\(anchorUpdate.trackingStateReason))"
                }
            } else {
                updateText = "Unavailable"
            }
        } else {
            updateText = "No anchors tracked"
        }
        
        super.updateInfoLabel(text: "VPS2 State: \(stateText), Anchor Update: \(updateText)")
    }
}

// MARK: - Scene Graph Management
extension VPS2ViewController {
    /// Returns the anchor in the screne graph associated with the vps anchor id.
    /// If the anchor does not exist, it will be created.
    @discardableResult
    private func getOrCreateSceneAnchor(anchorId: NsdkVpsAnchorId) -> AnchorEntity {
        if let existing = anchors[anchorId] { return existing }

        let anchor = AnchorEntity(world: .zero)
        anchor.name = String(describing: anchorId)
        arView.scene.addAnchor(anchor)
        anchors[anchorId] = anchor
        return anchor
    }

    /// Loads the results of a mesh download at the specified scene anchor.
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

        // Create the mesh
        let arrowModel = makeArrowEntity()

        // Arrow mesh is built along +Y; rotate so it points along -Z in *its local space*
        arrowModel.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])

        // World-space anchor that we'll manually position in front of the camera
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(arrowModel)

        arView.scene.addAnchor(anchor)
        poiArrow = anchor
    }

    private func updatePoiArrowInWorld() {
        guard
            let poiAnchorId,
            let poiAnchor = anchors[poiAnchorId],
            let poiArrow = poiArrow,
            let frame = arView.session.currentFrame
        else { return }

        // Show the arrow when we have at least coarse location (.limited or .tracked).
        guard lastPoiAnchorUpdate?.trackingState == .limited else {
            poiArrow.isEnabled = false
            return
        }

        let cameraTransform = frame.camera.transform

        // Camera world position
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Camera forward in world space (RealityKit cameras look along -Z)
        let cameraForward = -SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        )

        // Place the arrow some distance in front of the camera
        let distance: Float = 0.5
        let arrowWorldPosition = cameraPosition + cameraForward * distance
        poiArrow.position = arrowWorldPosition

        // World position of the POI
        let poiWorldPosition = poiAnchor.position(relativeTo: nil)

        // Direction from arrow to POI
        let dir = simd_normalize(poiWorldPosition - arrowWorldPosition)
        let forward = SIMD3<Float>(0, 0, -1)
        let q = simd_quatf(from: forward, to: dir)

        // Rotate the whole arrow anchor so the child mesh points toward the POI
        poiArrow.orientation = q

        // Compute vector from camera to POI
        var toPoi = poiWorldPosition - cameraPosition

        // If the camera is near the POI, hide the arrow
        let isNearPoi = simd_length_squared(toPoi) < 5.0

        // Get direction to POI
        toPoi = simd_normalize(toPoi)

        // If the camera is looking at the POI within the cone, hide the arrow
        let angleDegrees: Float = 40.0
        let cosThreshold = cos(angleDegrees * (.pi / 180.0))
        let dot = simd_dot(cameraForward, toPoi)
        let isLookingAtPoi = dot >= cosThreshold

        // Set visibility
        poiArrow.isEnabled = !isLookingAtPoi || !isNearPoi
    }

    /// Constructs the arrow model used to point towards the POI.
    private func makeArrowEntity(
        shaftLength: Float = 0.20,
        shaftRadius: Float = 0.006,
        headLength: Float = 0.06,
        headRadius: Float = 0.02,
        color: UIColor = .red
    ) -> ModelEntity {
        let material = SimpleMaterial(color: color, isMetallic: false)

        // Shaft (cylinder centered at origin by default)
        let shaftMesh = MeshResource.generateCylinder(height: shaftLength, radius: shaftRadius)
        let shaft = ModelEntity(mesh: shaftMesh, materials: [material])

        // Move shaft so its base starts at y=0 and it extends upward
        shaft.position = [0, shaftLength * 0.5, 0]

        // Head (cone points up; also centered at origin by default)
        let headMesh = MeshResource.generateCone(height: headLength, radius: headRadius)
        let head = ModelEntity(mesh: headMesh, materials: [material])

        // Place head on top of shaft
        head.position = [0, shaftLength + headLength * 0.5, 0]

        // Parent container so the arrow behaves like one object
        let arrow = ModelEntity()
        arrow.addChild(shaft)
        arrow.addChild(head)

        return arrow
    }

    /// Constructs the marker model used to indicate the POI's coarse location.
    private func makeCubeEntity(
        size: Float = 0.1,
        color: UIColor = .systemRed
    ) -> ModelEntity {
        let material = SimpleMaterial(color: color, isMetallic: false)
        let mesh = MeshResource.generateBox(size: size)
        let cube = ModelEntity(mesh: mesh, materials: [material])

        return cube
    }
}

// MARK: - Map related helpers
extension VPS2ViewController {
    /// Attempts to update the POI location on the map view.
    private func updatePoiLocationOnMap() {
        guard let poiAnchorId,
              let poiAnchor = anchors[poiAnchorId],
              let poiLocation = getLocation(for: poiAnchor.transform.matrix) else { return }

        lastPoiCoordinate = poiLocation.location
        updateIndicator(poiLocationIndicator, to: poiLocation.location, heading: poiLocation.heading)
    }

    /// Attempts to update the user location on the map view.
    private func updateUserLocationOnMap() {
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
        let userTransform = arView.session.currentFrame?.camera.displayOrientedTransform(orientation: orientation)
        guard let userTransform,
              let userLocation = getLocation(for: userTransform) else { return }

        lastUserCoordinate = userLocation.location
        updateIndicator(userLocationIndicator, to: userLocation.location, heading: userLocation.heading)
    }

    /// Updates a custom indicator view to the given coordinate (and optional heading) within the map view.
    ///
    /// - Parameters:
    ///   - indicator: The indicator view to update.
    ///   - coordinate: The coordinate the indicator should represent.
    ///   - heading: Optional heading (in degrees) to apply to the indicator.
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

    /// Recenters/zooms the map to keep both the user and POI coordinates visible.
    ///
    /// This is throttled by `mapRefreshInterval` to avoid excessive region updates.
    /// - Parameter animated: Whether the map adjustment should be animated.
    private func refreshMapViewportIfNeeded(animated: Bool = true) {
        guard let lastPoiCoordinate, let lastUserCoordinate else { return }

        let p0 = MKMapPoint(lastPoiCoordinate)
        let p1 = MKMapPoint(lastUserCoordinate)

        // The "needed" rect: minimal rect that contains both points.
        var needed = MKMapRect.null
        needed = needed.union(MKMapRect(origin: p0, size: .init(width: 0, height: 0)))
        needed = needed.union(MKMapRect(origin: p1, size: .init(width: 0, height: 0)))
        needed = needed.expandedToMinimumSize(200)

        // Current visible rect (in map points).
        let current = mapView.visibleMapRect

        // Visibility check
        let visibilityInsetFraction: Double = 0.08 // keep points away from edges
        let insetX = current.size.width * visibilityInsetFraction
        let insetY = current.size.height * visibilityInsetFraction
        let comfortableVisible = current.insetBy(dx: insetX, dy: insetY)

        let bothVisible = comfortableVisible.contains(p0) && comfortableVisible.contains(p1)

        // "Too zoomed out" check
        let currentArea = max(current.size.width * current.size.height, 1)
        let neededArea = max(needed.size.width * needed.size.height, 1)
        let zoomOutFactor = currentArea / neededArea

        let maxZoomOutFactor: Double = 4.0
        let tooZoomedOut = zoomOutFactor > maxZoomOutFactor

        guard !bothVisible || tooZoomedOut else { return }

        let edgePadding: UIEdgeInsets = .init(top: 80, left: 80, bottom: 80, right: 80)
        mapView.setVisibleMapRect(needed, edgePadding: edgePadding, animated: animated)
    }
}

private extension MKMapRect {
    /// Returns a rect expanded (about its center) to ensure it meets a minimum width/height.
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

class GeolocationIndicatorView: UIView {
    var heading: CGFloat = 0 { didSet { setNeedsDisplay() } }
    var displaysHeading: Bool = false
    var color: UIColor = .blue

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let center = CGPoint(x: rect.midX, y: rect.midY)

        // Draw dot
        ctx.setFillColor(color.cgColor)
        ctx.addEllipse(in: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
        ctx.fillPath()

        // Draw triangle (vision cone)
        if displaysHeading {
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: heading * .pi / 180)

            let path = UIBezierPath()
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: -12, y: -30))
            path.addLine(to: CGPoint(x: 12, y: -30))
            path.close()

            ctx.setFillColor(color.withAlphaComponent(0.2).cgColor)

            ctx.addPath(path.cgPath)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}
