// Copyright 2026 Niantic Spatial.

import Foundation
import ARKit
import NSDK
import Combine

/// Per-frame AR state, updated by ARManager's frame loop.
///
/// Separates @Published state from UIViewController so that ViewModels
/// depend on a plain object, not a ViewController.
final class ARFrameState {

    @Published private(set) var camera: NSDKCamera?
    @Published private(set) var trackingState: ARCamera.TrackingState = .notAvailable
    @Published private(set) var anchorsIsEmpty: Bool = true

    func update(camera: NSDKCamera?) {
        self.camera = camera
    }

    func update(trackingState: ARCamera.TrackingState) {
        self.trackingState = trackingState
    }

    func update(anchorsIsEmpty: Bool) {
        self.anchorsIsEmpty = anchorsIsEmpty
    }
}
