// Copyright 2026 Niantic Spatial.

import ARKit
import Metal
import NSDK
import RealityKit
import simd
import UIKit

/// Owns the RealityKit scene graph and the Metal mesh overlay for the VPS2 screen.
///
/// Manages the asset marker, the user-placed markers, a directional arrow that leads the user to
/// the most recently placed marker, and the localized area's downloaded mesh. The mesh is drawn
/// by `MeshRenderer` from the view's postProcess render callback, following the asset marker's
/// pose and visibility. `clear()` tears down all scene state.
final class VPS2SceneRenderer {

    private let nsdkView: NSDKView

    // MARK: - State

    private let assetMarker = Entity()
    private var assetAnchor: AnchorEntity?
    private var assetFallbackMarker: Entity?

    /// Whether VPS2 is serving the asset's pose.
    private var hasAssetPose = false

    /// Whether ARKit tracking is normal, so the world-locked marker keeps its last pose.
    private var isARTrackingNormal = false
    private var guideArrow: AnchorEntity?

    /// Where the guide arrow points, in AR tracking space, or `nil` while it is hidden.
    private var guidanceTargetPosition: SIMD3<Float>?

    /// How far in front of the camera the arrow floats.
    private let arrowDistanceMeters: Float = 0.5

    /// Within this distance of the target the arrow hides while the user looks toward it.
    private let arrowHideDistanceMeters: Float = 2

    /// Half-angle of the cone in front of the camera that counts as looking at the target.
    private let arrowHideHalfAngleDegrees: Float = 40
    private var placedAnchors: [UUID: AnchorEntity] = [:]
    private var anchorNodes: [NSDKVpsAnchorId: (anchor: AnchorEntity, state: VpsAnchorUpdate.AnchorTrackingState)] = [:]

    /// Draws the downloaded mesh chunks over the rendered frame. The camera passthrough stays
    /// visible through the wireframe, which makes it possible to tell whether the mesh is
    /// aligned with the real world.
    nonisolated private let meshRenderer: MeshRenderer

    /// Guards `meshWorldTransform` and `cameraViewMatrix`, which the main thread writes and the
    /// mesh overlay reads on the render thread. Both are `nonisolated(unsafe)` so the overlay can
    /// reach them in a module whose default actor isolation is `MainActor`.
    nonisolated private let meshTransformLock = NSLock()

    /// The asset pose the mesh renders at, or nil while the asset marker is hidden.
    nonisolated(unsafe) private var meshWorldTransform: simd_float4x4?

    /// The latest frame's view matrix for the interface orientation. The render thread reads
    /// this copy because `ARView.cameraTransform` is main-actor isolated.
    nonisolated(unsafe) private var cameraViewMatrix: simd_float4x4?

    /// Draws the mesh in playback mode, layered between the playback camera view and the
    /// NSDKView. Live mode uses the postProcess render callback instead; installing one on the
    /// nonAR playback view traps inside RealityKit.
    private var playbackMeshView: VPS2PlaybackMeshView?

    /// The VPS map asset whose mesh chunks are accepted.
    private var meshAssetId: String?

    /// Every downloaded chunk of `meshAssetId`, by area, so an area rebuilds without a download.
    private var areaChunks: [String: [MeshDownloaderChunk]] = [:]

    /// How many areas keep chunks resident in the mesh renderer, the shown one included.
    private let areaMeshCacheSize: Int

    /// Resident renderer chunk ids per area; an area evicted from here drops its chunks.
    private var loadedAreaChunkIds: [String: [Int64]] = [:]

    /// Areas in `loadedAreaChunkIds`, least recently shown first.
    private var recentAreaIds: [String] = []
    private var shownAreaId: String?
    private var nextChunkId: Int64 = 0

    // MARK: - Initialization

    init(nsdkView: NSDKView, areaMeshCacheSize: Int) {
        self.nsdkView = nsdkView
        self.areaMeshCacheSize = max(1, areaMeshCacheSize)
        let device = MTLCreateSystemDefaultDevice()!
        self.meshRenderer = MeshRenderer(device: device)

        let fallbackCube = makeCubeEntity(size: 1.0, color: .red)
        assetFallbackMarker = fallbackCube
        assetMarker.addChild(fallbackCube)

        switch nsdkView.sessionMode {
        case .live:
            // Installed for the whole screen lifetime; `clear()` removes it. RealityKit invokes
            // it on its render thread, so it is `@Sendable` to keep it off the main actor.
            nsdkView.renderCallbacks.postProcess = { @Sendable [weak self] context in
                self?.encodeMeshOverlay(context: context)
            }
        case .playback:
            playbackMeshView = VPS2PlaybackMeshView(
                nsdkView: nsdkView,
                meshRenderer: meshRenderer,
                device: device,
                worldTransform: { [weak self] in self?.currentMeshWorldTransform() }
            )
            attachPlaybackMeshViewIfNeeded()
        }
    }

    /// Inserts the playback mesh view below the NSDKView once the NSDKView is in a hierarchy.
    /// Called again from the per-frame camera update to cover a late insertion.
    private func attachPlaybackMeshViewIfNeeded() {
        guard
            let playbackMeshView,
            playbackMeshView.superview == nil,
            let container = nsdkView.superview
        else { return }
        playbackMeshView.translatesAutoresizingMaskIntoConstraints = false
        container.insertSubview(playbackMeshView, belowSubview: nsdkView)
        NSLayoutConstraint.activate([
            playbackMeshView.topAnchor.constraint(equalTo: container.topAnchor),
            playbackMeshView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            playbackMeshView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playbackMeshView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    // MARK: - Localized Asset

    /// Places the asset marker at the asset's origin. Without tracking data the marker holds its
    /// last pose while AR tracking is normal, and hides otherwise.
    func updateAssetMarker(transform: simd_float4x4?) {
        hasAssetPose = transform != nil
        guard let transform else {
            updateAssetMarkerVisibility()
            return
        }
        let anchor: AnchorEntity
        if let existing = assetAnchor {
            anchor = existing
        } else {
            let created = AnchorEntity(world: .zero)
            created.addChild(assetMarker)
            nsdkView.scene.addAnchor(created)
            assetAnchor = created
            anchor = created
        }
        anchor.transform = Transform(matrix: transform)
        updateAssetMarkerVisibility()
        assetMarker.isEnabled = true
    }

    /// Records ARKit's tracking state for the asset marker's hold-or-hide decision.
    func updateARTrackingState(_ state: ARCamera.TrackingState) {
        if case .normal = state {
            isARTrackingNormal = true
        } else {
            isARTrackingNormal = false
        }
        updateAssetMarkerVisibility()
    }

    /// Hides the asset marker only when neither VPS2 nor ARKit can place it.
    private func updateAssetMarkerVisibility() {
        assetAnchor?.isEnabled = hasAssetPose || isARTrackingNormal
        syncMeshTransform()
    }

    /// Mirrors the asset anchor's pose and visibility to the render thread for the mesh overlay.
    private func syncMeshTransform() {
        var transform: simd_float4x4?
        if let assetAnchor, assetAnchor.isEnabled {
            transform = assetAnchor.transform.matrix
        }
        meshTransformLock.lock()
        meshWorldTransform = transform
        meshTransformLock.unlock()
    }

    /// The asset pose the mesh renders at, or nil while hidden. Safe to call from any thread.
    nonisolated private func currentMeshWorldTransform() -> simd_float4x4? {
        meshTransformLock.lock()
        defer { meshTransformLock.unlock() }
        return meshWorldTransform
    }

    // MARK: - Placed markers

    /// Creates, repositions and prunes the user-placed cubes to match `markers`. Each cube
    /// takes its marker's colour so it pairs visibly with the dot on the map.
    func updatePlacedMarkers(_ markers: [VPS2PlacedMarker]) {
        for marker in markers {
            guard let transform = marker.transform else {
                placedAnchors[marker.id]?.isEnabled = false
                continue
            }
            let anchor: AnchorEntity
            if let existing = placedAnchors[marker.id] {
                anchor = existing
            } else {
                let created = AnchorEntity(world: .zero)
                created.addChild(makeCubeEntity(size: 0.25, color: marker.color))
                nsdkView.scene.addAnchor(created)
                placedAnchors[marker.id] = created
                anchor = created
            }
            anchor.transform = Transform(matrix: transform)
            anchor.isEnabled = true
        }

        let liveIds = Set(markers.map(\.id))
        for (id, anchor) in placedAnchors where !liveIds.contains(id) {
            anchor.removeFromParent()
            placedAnchors.removeValue(forKey: id)
        }
    }

    // MARK: - Anchors

    /// Creates, repositions, restyles and prunes the cubes for tap-created VPS anchors.
    /// `.tracked` anchors get a small green cube; `.limited` (coarse) anchors a large orange
    /// one; `.notTracked` anchors carry no pose and are hidden.
    func updateAnchors(_ anchors: [VPS2Anchor]) {
        for anchor in anchors {
            guard let transform = anchor.transform else {
                anchorNodes[anchor.id]?.anchor.isEnabled = false
                continue
            }

            let isTracked = anchor.trackingState == .tracked
            let color: UIColor = isTracked ? .systemGreen : .systemOrange
            let size: Float = isTracked ? 0.2 : 1.0

            if let node = anchorNodes[anchor.id] {
                node.anchor.isEnabled = true
                node.anchor.transform = Transform(matrix: transform)

                // Swap the cube only when the state (and so its colour/size) changes.
                if node.state != anchor.trackingState {
                    node.anchor.children.removeAll()
                    node.anchor.addChild(makeCubeEntity(size: size, color: color))
                    anchorNodes[anchor.id]?.state = anchor.trackingState
                }
            } else {
                let created = AnchorEntity(world: .zero)
                created.addChild(makeCubeEntity(size: size, color: color))
                created.transform = Transform(matrix: transform)
                nsdkView.scene.addAnchor(created)
                anchorNodes[anchor.id] = (anchor: created, state: anchor.trackingState)
            }
        }

        let liveIds = Set(anchors.map(\.id))
        for (id, node) in anchorNodes where !liveIds.contains(id) {
            node.anchor.removeFromParent()
            anchorNodes.removeValue(forKey: id)
        }
    }

    // MARK: - Guide arrow

    private func createGuideArrowIfNeeded() {
        guard guideArrow == nil else { return }

        let arrowModel = makeArrowEntity()
        arrowModel.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])

        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(arrowModel)

        nsdkView.scene.addAnchor(anchor)
        guideArrow = anchor
    }

    /// Points the guide arrow at `transform`'s position, or hides it when `nil`.
    func updateGuidanceTarget(transform: simd_float4x4?) {
        guidanceTargetPosition = transform?.translation
        if guidanceTargetPosition != nil {
            createGuideArrowIfNeeded()
        } else {
            guideArrow?.isEnabled = false
        }
    }

    /// Records the frame's view matrix for the mesh overlay and re-aims the guide arrow. Call
    /// once per frame.
    func updateCamera(_ camera: NSDKCamera) {
        attachPlaybackMeshViewIfNeeded()

        // The postProcess projection is built for the interface orientation, so the view matrix
        // must be too. The raw camera transform is in the sensor's landscape-right frame.
        let orientation = nsdkView.window?.windowScene?.interfaceOrientation ?? .portrait
        let viewMatrix = camera.viewMatrix(for: orientation)
        meshTransformLock.lock()
        cameraViewMatrix = viewMatrix
        meshTransformLock.unlock()
        updateGuideArrow(camera: camera)
    }

    /// Floats the arrow in front of the camera, pointing at the guidance target. Hidden
    /// while the user is near the target and looking toward it.
    private func updateGuideArrow(camera: NSDKCamera) {
        guard let guideArrow, let targetPosition = guidanceTargetPosition else { return }

        let cameraPosition = camera.transform.translation
        let cameraForward = camera.transform.forward
        let arrowPosition = cameraPosition + cameraForward * arrowDistanceMeters

        guideArrow.position = arrowPosition
        guideArrow.orientation = simd_quatf(
            from: SIMD3<Float>(0, 0, -1),
            to: simd_normalize(targetPosition - arrowPosition)
        )
        guideArrow.isEnabled = !isNearAndFacing(
            targetPosition, from: cameraPosition, forward: cameraForward)
    }

    /// Whether `target` is within the hide distance of `position` and inside the hide cone
    /// around `forward`.
    private func isNearAndFacing(
        _ target: SIMD3<Float>, from position: SIMD3<Float>, forward: SIMD3<Float>
    ) -> Bool {
        let toTarget = target - position
        let isNear = simd_length(toTarget) < arrowHideDistanceMeters
        let cosHalfAngle = cos(arrowHideHalfAngleDegrees * .pi / 180)
        let isFacing = simd_dot(forward, simd_normalize(toTarget)) >= cosHalfAngle
        return isNear && isFacing
    }

    // MARK: - Mesh

    /// Composites the mesh between the camera background and the RealityKit content: the scene
    /// depth keeps the markers and arrow on top of the mesh. Runs on the render thread, so it
    /// only touches `meshRenderer` and the lock-guarded transforms.
    nonisolated private func encodeMeshOverlay(context: ARView.PostProcessContext) {
        // With a postProcess callback installed, RealityKit stops filling the target itself,
        // so blit the rendered frame through first.
        guard let blitEncoder = context.commandBuffer.makeBlitCommandEncoder() else { return }
        blitEncoder.copy(from: context.sourceColorTexture, to: context.targetColorTexture)
        blitEncoder.endEncoding()

        meshTransformLock.lock()
        let worldTransform = meshWorldTransform
        let viewMatrix = cameraViewMatrix
        meshTransformLock.unlock()
        guard let worldTransform, let viewMatrix else { return }

        meshRenderer.encode(
            commandBuffer: context.commandBuffer,
            outputTexture: context.targetColorTexture,
            sceneDepthTexture: context.sourceDepthTexture,
            viewMatrix: viewMatrix,
            projectionMatrix: context.projection,
            worldTransform: worldTransform
        )
    }

    /// Uploads one chunk to the mesh renderer, hidden unless its area is the shown one. The
    /// downloader hands back an empty texture buffer for untextured assets.
    private func loadChunk(_ chunk: MeshDownloaderChunk) {
        let id = nextChunkId
        nextChunkId += 1
        let textureData = chunk.imageData.dataSize > 0
            ? Data(bytes: chunk.imageData.data, count: Int(chunk.imageData.dataSize))
            : nil
        meshRenderer.setChunk(
            id: id,
            meshData: chunk.meshData,
            textureData: textureData,
            transform: chunk.transform,
            hidden: chunk.areaId != shownAreaId
        )
        loadedAreaChunkIds[chunk.areaId, default: []].append(id)
    }

    /// Drops all mesh state and accepts chunks for `vpsMapAssetId` only.
    func resetAssetMesh(vpsMapAssetId: String?) {
        meshRenderer.removeAllChunks()
        loadedAreaChunkIds.removeAll()
        recentAreaIds.removeAll()
        shownAreaId = nil
        areaChunks.removeAll()
        meshAssetId = vpsMapAssetId
        assetFallbackMarker?.isEnabled = true
    }

    /// Stores one downloaded chunk and uploads it when its area is resident in the renderer.
    func addAssetMeshChunk(_ chunk: MeshDownloaderChunk) {
        // A chunk still in flight from a cancelled download names the previous asset.
        guard chunk.vpsMapAssetId == meshAssetId else { return }
        areaChunks[chunk.areaId, default: []].append(chunk)
        if loadedAreaChunkIds[chunk.areaId] != nil {
            loadChunk(chunk)
            updateFallbackMarker()
        }
    }

    /// Shows `areaId`'s mesh, uploading it from the stored chunks when needed, and drops the
    /// chunks of the least recently shown areas beyond the cache size.
    /// An empty `areaId` names the asset of a single-area site.
    func showAssetMeshArea(_ areaId: String) {
        shownAreaId = areaId
        if loadedAreaChunkIds[areaId] == nil {
            loadedAreaChunkIds[areaId] = []
            for chunk in areaChunks[areaId] ?? [] {
                loadChunk(chunk)
            }
        }
        recentAreaIds.removeAll { $0 == areaId }
        recentAreaIds.append(areaId)
        while recentAreaIds.count > areaMeshCacheSize {
            let evicted = recentAreaIds.removeFirst()
            for id in loadedAreaChunkIds.removeValue(forKey: evicted) ?? [] {
                meshRenderer.removeChunk(id: id)
            }
        }
        for (area, ids) in loadedAreaChunkIds {
            let hidden = area != areaId
            for id in ids {
                meshRenderer.setChunkHidden(hidden, id: id)
            }
        }
        updateFallbackMarker()
    }

    /// Shows the red cube until the shown area has geometry.
    private func updateFallbackMarker() {
        let shownChunkIds = shownAreaId.flatMap { loadedAreaChunkIds[$0] }
        assetFallbackMarker?.isEnabled = shownChunkIds?.isEmpty ?? true
    }

    // MARK: - Teardown

    func clear() {
        // The render-callback setter is what traps on the playback view, so only touch it in
        // live mode, where the callback was installed.
        if case .live = nsdkView.sessionMode {
            nsdkView.renderCallbacks.postProcess = nil
        }
        playbackMeshView?.isPaused = true
        playbackMeshView?.removeFromSuperview()
        playbackMeshView = nil
        guideArrow?.removeFromParent()
        guideArrow = nil
        assetAnchor?.removeFromParent()
        assetAnchor = nil
        syncMeshTransform()

        for anchor in placedAnchors.values {
            anchor.removeFromParent()
        }
        placedAnchors.removeAll()

        for node in anchorNodes.values {
            node.anchor.removeFromParent()
        }
        anchorNodes.removeAll()

        resetAssetMesh(vpsMapAssetId: nil)
        assetMarker.children.removeAll()
    }

    // MARK: - Entity factories

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
}

private extension simd_float4x4 {
    /// The translation column.
    var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }

    /// Where the transform's -Z axis points, which is forward for an ARKit camera.
    var forward: SIMD3<Float> {
        -SIMD3(columns.2.x, columns.2.y, columns.2.z)
    }
}
