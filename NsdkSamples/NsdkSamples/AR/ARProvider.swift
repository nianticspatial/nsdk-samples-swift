// Copyright 2026 Niantic Spatial.

import NSDK

/// A provider that participates in the per-frame update cycle managed by ARManager.
///
/// Each feature (Depth, Meshing, VPS2, etc.) implements this protocol to:
/// 1. Begin polling on `start`
/// 2. Poll for latest data on each frame via `update`
/// 3. Clean up on `stop`
///
/// Camera information is NOT passed through providers. ViewModels that need
/// camera data (for reprojection, geolocation, etc.) subscribe to
/// `arManager.$camera` directly.
///
/// This is a temporary abstraction. Once the SDK provides Push Sessions
/// with Combine publishers, providers will be removed and ViewModels
/// will subscribe to SDK Sessions directly.
protocol ARProvider: AnyObject {

    /// Called when the provider is registered with ARManager via `start(_:)`.
    func start()

    /// Called every frame after `nsdkSession.update()` has completed.
    /// Poll your SDK feature session for the latest data and update `@Published` properties.
    func update()

    /// Called when the provider is unregistered from ARManager via `stop(_:)`.
    func stop()
}
