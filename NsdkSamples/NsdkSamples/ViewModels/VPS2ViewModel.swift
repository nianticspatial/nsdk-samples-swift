// Copyright 2026 Niantic Spatial.

import Combine
import CoreLocation
import Foundation
import NSDK
import simd
import UIKit

/// Binds NSDKVps2Session Combine publishers into UI-ready state.
///
/// Subscribes to:
/// - `session.$latestLocalization` for the tracking state and the localized asset,
///   polling `assetTrackingData()` alongside each emission for the asset's pose
/// - `session.localizationRequestRecords` for error logging, the blur warning, and the site failure banner
///
/// Publishes:
/// - `statusText` (`String`): human-readable VPS + site/asset state. Initially `""`. Updated every frame.
/// - `trackingState` (`Vps2TrackingState`): the latest localization's tracking state. Initially `.unavailable`. Published on change.
/// - `placedMarkers` (`[VPS2PlacedMarker]`): user-placed markers with a freshly resolved AR pose. Initially empty. Re-posed every frame.
/// - `guidanceTargetTransform`: `simd_float4x4?`. AR pose of the most recently placed marker, for the guide arrow. Initially `nil`. `nil` while nothing is placed or VPS2 cannot resolve the pose. Re-posed every frame.
/// - `showMap` (`Bool`): whether the map overlay should be visible. Initially `false`. Set to `true` while asset tracking data is served.
/// - `userMapCoordinate` (`CLLocationCoordinate2D?`): device geolocation. Initially `nil`. Updated each localization + camera frame.
/// - `userMapHeading` (`CGFloat?`): device heading. Initially `nil`. Updated alongside `userMapCoordinate`.
/// - `localizedAsset` (`Vps2LocalizedAsset?`): the asset behind the most recent successful visual localization. Initially `nil`. Sticky until localization to its site is stopped. Changes when the device localizes in another area of the same asset.
/// - `localizedSiteName` (`String?`): display name of `localizedAsset`'s site. Initially `nil`. Cleared when `localizedAsset.assetId` changes; kept across area changes.
/// - `localizedAssetName` (`String?`): display name of `localizedAsset`. Initially `nil`. Cleared when `localizedAsset.assetId` changes; kept across area changes.
/// - `localizedAssetAreaCount` (`Int?`): how many areas `localizedAsset` is split into. Initially `nil`. Cleared when `localizedAsset.assetId` changes; kept across area changes. Rendered only above 1.
/// - `assetTrackingData` (`Vps2AssetTrackingData?`): pose of the localized asset's origin. Initially `nil`. `nil` whenever tracking is not full.
/// - `siteFailureText` (`String?`): user-facing message when the site's VPS assets cannot be fetched. Initially `nil`. Cleared when a later fetch succeeds.
/// - `isImageTooBlurry` (`Bool`): whether recent frames were flagged too blurry to localize well. Initially `false`. Set while flagged records arrive; cleared 2 s after they stop.
final class VPS2ViewModel {

    // MARK: - Published State

    @Published private(set) var statusText: String = ""

    @Published private(set) var trackingState: Vps2TrackingState = .unavailable

    @Published private(set) var placedMarkers: [VPS2PlacedMarker] = []

    /// AR pose of the most recently placed marker, for the guide arrow. Unlike the marker's own
    /// transform it is served under coarse tracking too: a coarse pose is accurate enough to
    /// point toward, though not to place a cube at.
    @Published private(set) var guidanceTargetTransform: simd_float4x4?

    /// VPS anchors created by tapping the AR view, with their latest pose and tracking state.
    @Published private(set) var anchors: [VPS2Anchor] = []

    @Published private(set) var showMap: Bool = false

    @Published private(set) var userMapCoordinate: CLLocationCoordinate2D?
    @Published private(set) var userMapHeading: CGFloat?

    @Published private(set) var localizedAsset: Vps2LocalizedAsset?

    /// Display name of `localizedAsset`'s site. `nil` until the Sites lookup lands or when
    /// `localizedAsset.assetId` changes; kept across area changes. Raw site ID is shown until
    /// this string is available.
    @Published private(set) var localizedSiteName: String?

    /// Display name of `localizedAsset` itself. `nil` until the Sites lookup lands or when
    /// `localizedAsset.assetId` changes; kept across area changes. Raw asset ID is shown until
    /// this string is available.
    @Published private(set) var localizedAssetName: String?

    /// How many areas `localizedAsset` is split into. `nil` until the Sites lookup lands or when
    /// `localizedAsset.assetId` changes; kept across area changes. Surfaced only above 1: a scan
    /// too large for one mapping run produces several areas, and VPS2 localizes against whichever
    /// one the device is standing in.
    @Published private(set) var localizedAssetAreaCount: Int?

    @Published private(set) var assetTrackingData: Vps2AssetTrackingData?

    @Published private(set) var siteFailureText: String?

    @Published private(set) var isImageTooBlurry: Bool = false

    // MARK: - Private

    /// A tap the user made on the map. Durable: the AR pose is derived from it every
    /// frame rather than stored, so the cubes follow VPS2's refinements.
    private struct Placement {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
        let altitude: Double
        let colorIndex: Int
    }

    private let session: NSDKVps2Session
    private var cancellables = Set<AnyCancellable>()
    private let meshLoader = MeshLoader()
    private let nameLoader = SiteNameLoader()
    private let blurFlagged = PassthroughSubject<Void, Never>()

    private var placements: [Placement] = []
    private var latestDeviceAltitude: Double?

    /// How far in front of the camera a long-press geotags.
    private let geotagDistanceMeters: Float = 2

    /// Created anchors keyed by id, updated from `anchorUpdated` and republished as `anchors`.
    private var anchorsById: [NSDKVpsAnchorId: VPS2Anchor] = [:]

    // MARK: - Initialization

    init(session: NSDKVps2Session) {
        self.session = session

        // The localization publisher fires every frame, so it doubles as the
        // polling clock for the asset tracking data. The discrete-valued
        // outputs only publish on change to spare SwiftUI per-frame updates;
        // the tracking data is a fresh pose each frame and passes through.
        session.$latestLocalization
            .sink { [weak self] localization in
                guard let self else { return }
                let localizedAsset = localization?.localizedAsset
                if self.localizedAsset != localizedAsset {
                    // Ids are all VPS2 reports; each name costs a portal round-trip. Cleared in
                    // lockstep with the ids, before the assignment publishes, so a name is never
                    // rendered beside a different asset's id. VPS2View starts the lookup.
                    // An area change within the same asset keeps the names.
                    if !Self.isSameAsset(self.localizedAsset, localizedAsset) {
                        self.localizedSiteName = nil
                        self.localizedAssetName = nil
                        self.localizedAssetAreaCount = nil
                    }
                    self.localizedAsset = localizedAsset
                }
                self.assetTrackingData = self.session.assetTrackingData()
                let showMap = self.assetTrackingData != nil
                if self.showMap != showMap {
                    self.showMap = showMap
                }
                let trackingState = localization?.trackingState ?? .unavailable
                if self.trackingState != trackingState {
                    self.trackingState = trackingState
                }
                self.updateStatus(localization: localization)
                self.updateMapIndicators(localization: localization)
                self.updatePlacedMarkers()
            }
            .store(in: &cancellables)

        // Subscribe to localization request records for error logging and the blur warning
        session.localizationRequestRecords
            .sink { [weak self] records in
                for record in records {
                    // Flagged records are advisory (the frame is still sent), so they
                    // drive user guidance instead of the failure log.
                    if record.status == .frameFlagged {
                        if record.error == .imageTooBlurry {
                            self?.blurFlagged.send()
                        }
                        continue
                    }

                    // A failed asset fetch is terminal for the site flow (nothing gets
                    // enrolled for localization), so it surfaces in the UI, unlike frame
                    // localize failures, which retry continuously. The latest fetch
                    // outcome wins: a retry that succeeds clears the message. A fetch that
                    // stopLocalize cancelled (Stop Localizing, or Switch Asset) ends failed
                    // with `.unknown`, and is not a failure to report.
                    if record.type == .assetInfo && record.error != .unknown {
                        self?.siteFailureText = record.error == .none
                            ? nil
                            : "Cannot localize to this site: \(record.error)"
                    }
                    if record.error != .none {
                        print("""
                            VPS2 localization request failed:
                              id: \(record.identifier)
                              type: \(record.type)
                              status: \(record.status)
                              error: \(record.error)
                            """)
                    }
                }
            }
            .store(in: &cancellables)

        // Show the blur warning while flagged frames arrive; hide it 2 s after they stop
        blurFlagged
            .sink { [weak self] _ in self?.isImageTooBlurry = true }
            .store(in: &cancellables)

        blurFlagged
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.isImageTooBlurry = false }
            .store(in: &cancellables)

        // Track anchors created via the AR-view tap. `anchorUpdated` fires each frame for
        // every tracked anchor; a `.notTracked` update carries no pose, so the cube hides.
        session.anchorUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id, update in
                guard let self else { return }
                self.anchorsById[id] = VPS2Anchor(
                    id: id,
                    transform: update.trackingData?.targetAnchorTransform,
                    trackingState: update.trackingState,
                    coordinate: update.trackingData?.geolocation.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                )
                self.anchors = Array(self.anchorsById.values)
            }
            .store(in: &cancellables)
    }

    // MARK: - Status

    private func updateStatus(localization: Vps2Localization?) {
        let stateText: String
        if let localization {
            stateText = String(describing: localization.trackingState)
        } else {
            stateText = "Unavailable"
        }

        // Fall back to raw IDs if human-readable names aren't available yet
        let siteText: String
        let assetText: String
        let areaText = localizedAsset?.areaId ?? "None"
        if let asset = localizedAsset {
            siteText = localizedSiteName ?? asset.siteId
            var text = localizedAssetName ?? asset.assetId

            // Only worth saying when the asset is split: one area is the ordinary case, and
            // "(1 area)" beside every asset would be noise.
            if let areaCount = localizedAssetAreaCount, areaCount > 1 {
                text += " (\(areaCount) areas)"
            }
            assetText = text
        } else {
            siteText = "None"
            assetText = "None"
        }

        let poseText: String
        if let tracking = assetTrackingData {
            poseText = String(format: "Tracked (%.2f)", tracking.confidence)
        } else {
            poseText = "No data"
        }

        // Until the names are resolved from Portal, print the raw UUIDs
        statusText = """
            VPS2: \(stateText), Pose: \(poseText)
            Site: \(siteText)
            Asset: \(assetText)
            Area: \(areaText)
            """
    }

    // MARK: - Map

    private func updateMapIndicators(localization: Vps2Localization?) {
        guard
            let localization,
            localization.trackingState != .unavailable
        else {
            userMapCoordinate = nil
            userMapHeading = nil
            return
        }

        let orientation = UIDevice.current.orientation
        let heading: HeadingMode = (orientation == .faceUp || orientation == .faceDown) ? .deviceTop : .cameraDirection
        guard let userGeo = session.deviceGeolocation(headingMode: heading) else { return }

        userMapCoordinate = CLLocationCoordinate2D(
            latitude: userGeo.geolocationData.latitude,
            longitude: userGeo.geolocationData.longitude
        )

        userMapHeading = CGFloat(userGeo.geolocationData.heading)

        // Placements reuse this rather than calling deviceGeolocation again. It is WGS84
        // ellipsoidal, the datum getPose expects, so a marker lands at device height.
        latestDeviceAltitude = userGeo.geolocationData.altitude
    }

    // MARK: - Placed markers

    /// Records a tapped coordinate to place a marker at.
    ///
    /// - Returns: `false` if tracking is not yet precise, or no device altitude is known.
    @discardableResult
    func placeMarker(at coordinate: CLLocationCoordinate2D) -> Bool {
        guard
            trackingState == .precise,
            let altitude = latestDeviceAltitude
        else { return false }

        placements.append(
            Placement(
                id: UUID(),
                coordinate: coordinate,
                altitude: altitude,
                colorIndex: placements.count
            )
        )
        updatePlacedMarkers()
        return true
    }

    /// Geotags the spot `geotagDistanceMeters` in front of the camera: VPS2 converts that AR
    /// pose to a geolocation with `getGeolocation(pose:)`, and the result is added as a
    /// placement. So it shows on the mini-map, and (resolved back through `getPose` in
    /// `updatePlacedMarkers()`) as a cube in AR that should sit where the camera was pointing,
    /// which makes the round trip visible.
    ///
    /// - Returns: The geolocation, or `nil` if tracking is not yet precise (the same rule as
    ///   `placeMarker(at:)`) or VPS2 could not convert the pose.
    @discardableResult
    func geotagInFront(cameraTransform: simd_float4x4) -> Vps2GeolocationData? {
        guard trackingState == .precise else { return nil }

        // Keep the camera's rotation so the geolocation's heading is the way the camera faces
        // (-Z is forward in ARKit).
        var offset = matrix_identity_float4x4
        offset.columns.3.z = -geotagDistanceMeters
        guard let geolocation = session.getGeolocation(pose: cameraTransform * offset) else {
            return nil
        }

        placements.append(
            Placement(
                id: UUID(),
                coordinate: CLLocationCoordinate2D(
                    latitude: geolocation.geolocationData.latitude,
                    longitude: geolocation.geolocationData.longitude
                ),
                altitude: geolocation.geolocationData.altitude,
                colorIndex: placements.count
            )
        )
        updatePlacedMarkers()
        return geolocation
    }

    /// Clears everything the user placed: map markers, long-press geotags and created AR anchors.
    func clearAll() {
        placements.removeAll()
        placedMarkers = []
        guidanceTargetTransform = nil

        for id in anchorsById.keys {
            session.removeAnchor(withId: id)
        }
        anchorsById.removeAll()
        anchors = []
    }

    // MARK: - Anchors

    /// Creates a VPS anchor 1 m in front of the camera (identity rotation), mirroring the
    /// Kotlin sample's tap-to-anchor flow. No-op unless tracking is `.precise`, since
    /// `createAnchor` throws otherwise.
    func createAnchor(cameraTransform: simd_float4x4) {
        guard trackingState == .precise else { return }

        let forward = -SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        )
        let position = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        ) + forward  // 1 m along the camera's forward axis

        var anchorPose = matrix_identity_float4x4
        anchorPose.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)

        do {
            let id = try session.createAnchor(at: anchorPose)

            // Seed as not-tracked; the cube appears once `anchorUpdated` reports a pose.
            anchorsById[id] = VPS2Anchor(id: id, transform: nil, trackingState: .notTracked(reason: nil), coordinate: nil)
            anchors = Array(anchorsById.values)
        } catch {
            print("Failed to create VPS2 anchor: \(String(describing: error))")
        }
    }

    private func updatePlacedMarkers() {
        guard !placements.isEmpty else { return }

        let poses = placements.map { placement in
            session.getPose(coordinate: placement.coordinate, altitude: placement.altitude)
        }
        placedMarkers = zip(placements, poses).map { placement, pose in
            // getPose reports the tracking state of the localization it used. Show a marker
            // only while that pose is precise: a coarse (WPS-only) pose would place it
            // inaccurately, so drop the transform until tracking sharpens back up.
            let transform = pose?.trackingState == .precise ? pose?.transform : nil
            return VPS2PlacedMarker(
                id: placement.id,
                coordinate: placement.coordinate,
                color: VPS2MarkerPalette.color(at: placement.colorIndex),
                transform: transform
            )
        }

        let latestPose = poses.last ?? nil
        guidanceTargetTransform = latestPose?.transform
    }

    // MARK: - Mesh

    func startMeshDownload(
        vpsMapAssetId: String,
        nsdkSession: NSDKSession,
        retryHelper: AuthRetryHelper,
        onChunk: @MainActor @escaping (MeshDownloaderChunk) -> Void
    ) {
        meshLoader.start(
            vpsMapAssetId: vpsMapAssetId,
            nsdkSession: nsdkSession,
            retryHelper: retryHelper,
            getCoordinate: { [weak self] in self?.userMapCoordinate },
            onChunk: onChunk
        )
    }

    func cancelMeshDownload() {
        meshLoader.cancel()
    }

    func releaseMeshDownloader(from nsdkSession: NSDKSession) {
        meshLoader.release(from: nsdkSession)
    }

    // MARK: - Names

    /// Resolves and publishes the display names of the localized site and asset, replacing any
    /// in-flight lookup.
    func startNameLookup(
        for asset: Vps2LocalizedAsset,
        nsdkSession: NSDKSession,
        retryHelper: AuthRetryHelper
    ) {
        nameLoader.start(
            siteId: asset.siteId,
            assetId: asset.assetId,
            nsdkSession: nsdkSession,
            retryHelper: retryHelper,
            // A reply already past its await when the localized asset changed would otherwise
            // name the wrong asset, so each write re-checks what it was requested for.
            onSiteName: { [weak self] name in
                guard let self, Self.isSameAsset(self.localizedAsset, asset) else { return }
                self.localizedSiteName = name
            },
            onAsset: { [weak self] name, areaCount in
                guard let self, Self.isSameAsset(self.localizedAsset, asset) else { return }
                self.localizedAssetName = name
                self.localizedAssetAreaCount = areaCount
            }
        )
    }

    /// Whether both name the same site and asset, whatever area each is in.
    static func isSameAsset(_ lhs: Vps2LocalizedAsset?, _ rhs: Vps2LocalizedAsset?) -> Bool {
        lhs?.siteId == rhs?.siteId && lhs?.assetId == rhs?.assetId
    }

    func cancelNameLookup() {
        nameLoader.cancel()
    }
}
