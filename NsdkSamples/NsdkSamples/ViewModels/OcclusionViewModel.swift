// Copyright 2026 Niantic Spatial.

import Foundation
import Metal
import simd
import NSDK
import Combine

/// Transforms raw depth data from NSDKDepthSession into display-ready state for occlusion rendering.
///
/// Subscribes to:
/// - `depthSession.$result` for depth results
///
/// Publishes:
/// - `depthTexture`: `MTLTexture?` — depth map image. Initially `nil`. Updated each frame with a new depth result.
/// - `intrinsics`: `matrix_float3x3` — camera intrinsics for the depth frame. Initially identity. Updated alongside the depth texture.
/// - `extrinsics`: `matrix_float4x4` — camera pose for the depth frame. Initially identity. Updated alongside the depth texture.
final class OcclusionViewModel {

    // MARK: - Published State

    @Published private(set) var depthTexture: MTLTexture?
    @Published private(set) var intrinsics: matrix_float3x3 = matrix_identity_float3x3
    @Published private(set) var extrinsics: matrix_float4x4 = matrix_identity_float4x4

    // MARK: - Private

    private let device: MTLDevice?
    private var texture: MTLTexture?
    private var lastFrameId: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(depthSession: NSDKDepthSession) {
        self.device = MTLCreateSystemDefaultDevice()

        // Extract successful results, logging errors at a single point
        let successResult = depthSession.$result
            .compactMap { state -> DepthResult? in
                switch state {
                case .success(let result):
                    return result
                case .failure(let error):
                    print("❌ [OcclusionViewModel] Depth result error: \(error)")
                    return nil
                case .inProgress, .notReady:
                    return nil
                @unknown default:
                    print("⚠️ [OcclusionViewModel] Unexpected depth result state.")
                    return nil
                }
            }

        // Subscribe to depth texture and camera matrix updates
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
                    self.intrinsics = result.intrinsics
                    self.extrinsics = result.pose
                }
            }
            .store(in: &cancellables)
    }
}
