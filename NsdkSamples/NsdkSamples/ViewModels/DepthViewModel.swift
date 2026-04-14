// Copyright 2026 Niantic Spatial.

import Foundation
import Metal
import simd
import NSDK
import Combine

/// Transforms raw depth data from NSDKDepthSession into display-ready textures.
///
/// Subscribes to:
/// - `depthSession.$result` for depth results
/// - `frameState.$camera` for reprojection
///
/// Publishes:
/// - `depthTexture`: `MTLTexture?` — depth map image. Initially `nil`. Updated each frame with a new depth result.
/// - `reprojection`: `matrix_float3x3` — camera-aligned reprojection matrix. Initially identity. Updated each frame alongside the depth result.
final class DepthViewModel {

    // MARK: - Published State

    @Published private(set) var depthTexture: MTLTexture?
    @Published private(set) var reprojection: matrix_float3x3 = matrix_identity_float3x3

    // MARK: - Private

    private let device: MTLDevice?
    private var texture: MTLTexture?
    private var lastFrameId: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(depthSession: NSDKDepthSession, frameState: ARFrameState) {
        self.device = MTLCreateSystemDefaultDevice()

        // Extract successful results, logging errors at a single point.
        // .share() ensures the compactMap (and its error logging) runs once
        // per event, regardless of how many downstream subscribers exist.
        let successResult = depthSession.$result
            .compactMap { state -> DepthResult? in
                switch state {
                case .success(let result):
                    return result
                case .failure(let error):
                    print("❌ [DepthViewModel] Depth result error: \(error)")
                    return nil
                case .inProgress, .notReady:
                    return nil
                @unknown default:
                    print("⚠️ [DepthViewModel] Unexpected depth result state.")
                    return nil
                }
            }
            .share()

        // Subscribe to depth texture updates
        successResult
            .sink { [weak self] result in
                guard let self, let device = self.device else { return }

                guard result.frameId != self.lastFrameId else { return }
                self.lastFrameId = result.frameId

                let didUpdate = TextureUtils.createOrUpdateTexture(
                    from: result.image,
                    texture: &self.texture,
                    device: device
                )

                if didUpdate {
                    self.depthTexture = self.texture
                }
            }
            .store(in: &cancellables)

        // Subscribe to camera for reprojection
        successResult
            .combineLatest(frameState.$camera)
            .sink { [weak self] result, camera in
                guard let camera else { return }
                self?.reprojection = result.calculateReprojection(to: camera.transform)
                    ?? matrix_identity_float3x3
            }
            .store(in: &cancellables)
    }
}
