// Copyright 2026 Niantic Spatial.

import Combine
import CoreLocation
import Foundation
import NSDK
import simd
import UIKit

/// Binds NSDKVps2Session Combine publishers and ARFrameState into UI-ready state.
///
/// Subscribes to:
/// - `session.anchorUpdated` for per-anchor pose and tracking state
/// - `session.localizationRequestRecords` for error logging
/// - `session.$latestLocalization` combined with `frameState.$camera` for status and map updates
///
/// Publishes:
/// - `statusText`: `String` — human-readable VPS + anchor state. Initially `""`. Updated on every localization or anchor change.
/// - `showMap`: `Bool` — whether the map overlay should be visible. Initially `false`. Set to `true` once any anchor reaches limited or tracked state.
/// - `userMapCoordinate`: `CLLocationCoordinate2D?` — device geolocation. Initially `nil`. Updated each localization + camera frame.
/// - `userMapHeading`: `CGFloat?` — device heading. Initially `nil`. Updated alongside `userMapCoordinate`.
/// - `poiMapCoordinate`: `CLLocationCoordinate2D?` — POI geolocation. Initially `nil`. Updated when a tracked POI anchor has geolocation data.
/// - `poiMapHeading`: `CGFloat?` — POI heading. Initially `nil`. Updated alongside `poiMapCoordinate`.
/// - `anchorWorldTransforms`: `[NSDKVpsAnchorId: simd_float4x4]` — per-anchor transforms. Initially empty. Derived from `anchorUpdatesById`.
/// - `anchorUpdatesById`: `[NSDKVpsAnchorId: VpsAnchorUpdate]` — latest per-anchor update records. Initially empty. Updated on every anchor event.
final class VPS2ViewModel {

    // MARK: - Input

    @Published var poiAnchorId: NSDKVpsAnchorId?

    // MARK: - Published State

    @Published private(set) var statusText: String = ""

    @Published private(set) var showMap: Bool = false

    @Published private(set) var userMapCoordinate: CLLocationCoordinate2D?
    @Published private(set) var userMapHeading: CGFloat?

    @Published private(set) var poiMapCoordinate: CLLocationCoordinate2D?
    @Published private(set) var poiMapHeading: CGFloat?

    @Published private(set) var anchorWorldTransforms: [NSDKVpsAnchorId: simd_float4x4] = [:]

    @Published private(set) var anchorUpdatesById: [NSDKVpsAnchorId: VpsAnchorUpdate] = [:]

    // MARK: - Private

    private let session: NSDKVps2Session
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(session: NSDKVps2Session, frameState: ARFrameState) {
        self.session = session

        // Subscribe to per-anchor pose and tracking state updates
        session.anchorUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id, update in
                guard let self else { return }
                var next = self.anchorUpdatesById
                next[id] = update
                self.anchorUpdatesById = next
                self.updateLocalizedFlag()
            }
            .store(in: &cancellables)

        // Subscribe to localization request records for error logging
        session.localizationRequestRecords
            .receive(on: DispatchQueue.main)
            .sink { records in
                for record in records where record.error != .none {
                    print("""
                        VPS2 localization request failed:
                          id: \(record.identifier)
                          type: \(record.type)
                          status: \(record.status)
                          error: \(record.error)
                        """)
                }
            }
            .store(in: &cancellables)

        // Derive world transforms from anchor updates
        $anchorUpdatesById
            .map { updates in
                updates.compactMapValues { $0.trackingData?.targetAnchorTransform }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transforms in
                self?.anchorWorldTransforms = transforms
            }
            .store(in: &cancellables)

        // Subscribe to combined localization + anchor + camera state for status and map
        Publishers.CombineLatest4(
            session.$latestLocalization,
            $anchorUpdatesById,
            $poiAnchorId,
            frameState.$camera
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] localization, anchorUpdates, poiId, camera in
            self?.updateStatus(localization: localization, anchorUpdates: anchorUpdates, poiId: poiId)
            self?.updateMapIndicators(
                localization: localization,
                anchorUpdates: anchorUpdates,
                poiId: poiId,
                camera: camera
            )
        }
        .store(in: &cancellables)
    }

    // MARK: - Localization (map visibility)

    private func updateLocalizedFlag() {
        showMap = anchorUpdatesById.values.contains { update in
            switch update.trackingState {
            case .limited, .tracked:
                return true
            case .notTracked:
                return false
            }
        }
    }

    // MARK: - Status

    private func updateStatus(
        localization: Vps2Localization?,
        anchorUpdates: [NSDKVpsAnchorId: VpsAnchorUpdate],
        poiId: NSDKVpsAnchorId?
    ) {
        let stateText: String
        if let localization {
            stateText = String(describing: localization.trackingState)
        } else {
            stateText = "Unavailable"
        }

        let anchorText: String
        if let poiId {
            if let anchorUpdate = anchorUpdates[poiId] {
                anchorText = String(describing: anchorUpdate.trackingState)
            } else {
                anchorText = "Unavailable"
            }
        } else {
            anchorText = "No anchors tracked"
        }

        statusText = "VPS2 State: \(stateText), Anchor Update: \(anchorText)"
    }

    // MARK: - Map

    private func updateMapIndicators(
        localization: Vps2Localization?,
        anchorUpdates: [NSDKVpsAnchorId: VpsAnchorUpdate],
        poiId: NSDKVpsAnchorId?,
        camera: NSDKCamera?
    ) {
        guard
            let localization,
            localization.trackingState != .unavailable,
            let camera
        else {
            userMapCoordinate = nil
            userMapHeading = nil
            poiMapCoordinate = nil
            poiMapHeading = nil
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

        if let poiId,
           let update = anchorUpdates[poiId],
           let tracking = update.trackingData, let poiGeo = tracking.geolocation {
            poiMapCoordinate = CLLocationCoordinate2D(
                latitude: poiGeo.latitude,
                longitude: poiGeo.longitude
            )
            poiMapHeading = CGFloat(poiGeo.heading)
        } else {
            poiMapCoordinate = nil
            poiMapHeading = nil
        }
    }
}
