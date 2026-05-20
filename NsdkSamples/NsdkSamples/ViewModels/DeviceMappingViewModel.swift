// Copyright 2026 Niantic Spatial.

import Foundation
import Combine
import NSDK
import simd

/// Transforms device-mapping and VPS data streams into view-ready published state.
///
/// Subscribes to:
/// - `mappingSession.$latestMapUpdate` for incremental map buffers
/// - `vps2Session.anchorUpdated` for per-frame anchor pose updates
///
/// Publishes:
/// - `rootAnchorPayload`: `String?` — base64 anchor payload for the map origin. Initially `nil` (or bootstrapped from storage). Set once after first map update creates a root anchor.
/// - `anchorTransform`: `simd_float4x4?` — anchor-to-ARKit transform. Initially `nil`. Updated every VPS anchor event.
/// - `points`: `[SIMD3<Float>]` — accumulated feature points in anchor-local space. Initially empty. Grown incrementally as each VPS anchor event drains the pending-map queue.
final class DeviceMappingViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var anchorTransform: simd_float4x4?
    @Published private(set) var points: [SIMD3<Float>] = []
    @Published private(set) var rootAnchorPayload: String?

    // MARK: - Private

    private let mapStorage: NSDKMapStorage
    private var pendingMaps: [NSDKBuffer] = []
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(
        mappingSession: NSDKDeviceMappingSession,
        mapStorage: NSDKMapStorage,
        vps2Session: NSDKVps2Session
    ) {
        self.mapStorage = mapStorage

        // Bootstrap from any map already in storage (e.g. loaded from disk by the caller).
        if let mapBuffer = mapStorage.mapData(), let anchor = mapStorage.createRootAnchor() {
            rootAnchorPayload = anchor
            pendingMaps = [mapBuffer]
        }

        // Subscribe to incremental map updates
        mappingSession.$latestMapUpdate
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buffer in
                self?.handleMapUpdate(buffer)
            }
            .store(in: &cancellables)

        // Subscribe to VPS anchor pose updates
        vps2Session.anchorUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, update in
                self?.handleAnchorUpdate(update)
            }
            .store(in: &cancellables)
    }

    // MARK: - Mapping Lifecycle

    /// Clears mapping-derived state so a new mapping pass can recreate the root anchor and
    /// re-register VPS tracking after the previous session was stopped.
    func resetForNewMapping() {
        rootAnchorPayload = nil
        pendingMaps.removeAll()
        points.removeAll()
        anchorTransform = nil
    }

    // MARK: - Private Handlers

    private func handleMapUpdate(_ buffer: NSDKBuffer) {
        if rootAnchorPayload == nil, let anchor = mapStorage.createRootAnchor() {
            rootAnchorPayload = anchor
        }
        guard rootAnchorPayload != nil else { return }
        pendingMaps.append(buffer)
    }

    private func handleAnchorUpdate(_ update: VpsAnchorUpdate) {
        guard let trackingData = update.trackingData,
              let anchorPayload = rootAnchorPayload else { return }

        anchorTransform = trackingData.targetAnchorTransform

        guard !pendingMaps.isEmpty else { return }

        var newPoints: [SIMD3<Float>] = []
        for mapBuffer in pendingMaps {
            do {
                guard let metadata = try mapStorage.extractMapMetadata(
                    anchorPayload: anchorPayload, map: mapBuffer
                ) else { continue }
                let flat = metadata.points
                newPoints.reserveCapacity(newPoints.count + Int(metadata.pointsCount))
                stride(from: 0, to: flat.count - 2, by: 3).forEach { i in
                    newPoints.append(SIMD3<Float>(flat[i], flat[i + 1], flat[i + 2]))
                }
            } catch {
                print("[DeviceMappingViewModel] Metadata extraction failed: \(error)")
            }
        }

        if !newPoints.isEmpty {
            points.append(contentsOf: newPoints)
        }
        pendingMaps.removeAll()
    }
}
