// Copyright 2026 Niantic Spatial.

import CoreLocation
import NSDK
import simd

/// A VPS anchor created by tapping the AR view, rendered as a cube whose colour and size
/// reflect the anchor's tracking state.
struct VPS2Anchor {
    let id: NSDKVpsAnchorId
    /// The anchor's pose in AR space, refreshed each frame. `nil` while the anchor is
    /// `.notTracked` (no pose to show yet).
    let transform: simd_float4x4?
    let trackingState: VpsAnchorUpdate.AnchorTrackingState
    /// The anchor's VPS2 geolocation, for plotting on the mini-map. `nil` while `.notTracked`
    /// or when VPS2 has no geolocation for it yet.
    let coordinate: CLLocationCoordinate2D?
}
