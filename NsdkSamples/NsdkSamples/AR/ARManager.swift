// Copyright 2026 Niantic Spatial.

import UIKit
import ARKit
import RealityKit
import NSDK
import Combine

/// Manages AR rendering infrastructure without requiring ViewController inheritance.
///
/// Provides:
/// - NSDKView (Live / Playback) setup
/// - DataSource bridging NSDKView.session → NSDKSession
/// - ARSession lifecycle (start / stop)
/// - Per-frame update loop (nsdkSession.update, ARFrameState, provider polling)
/// - Screen orientation reporting via UIOrientationReporter (computed property)
///
/// Features that only need NSDKSession for API calls (Sites, VpsCoverage, etc.)
/// should use NSDKSession directly — they do not need ARManager.
///
/// Inject ARManager into your ViewController and call `startSession()` / `stopSession()`.
class ARManager: NSObject, UIOrientationReporter {

    // MARK: - Public Properties

    let nsdkSession: NSDKSession
    let nsdkView: NSDKView
    let frameState = ARFrameState()

    // MARK: - Orientation (computed property — no caching needed)

    var currentOrientation: NSDKScreenOrientation {
        let orientation = nsdkView.window?.windowScene?.interfaceOrientation ?? .unknown
        return NSDKScreenOrientation(orientation)
    }

    // MARK: - Private

    private var dataSource: NSDKSessionDataSource?
    private var providers: [ARProvider] = []
    private static let playbackDatasetDirectory = "" //<-- PUT_PLAYBACK_DATASET_DIRECTORY_NAME_HERE

    // MARK: - Initialization

    init(nsdkSession: NSDKSession) {
        self.nsdkSession = nsdkSession

        if let dataset = BundlePlaybackDatasetLoader(directory: Self.playbackDatasetDirectory).loadDataset() {
            nsdkView = NSDKView(dataset: dataset)
        } else {
            nsdkView = NSDKView()
        }

        super.init()

        setupDataSource()
        nsdkView.delegate = self
    }

    // MARK: - Provider Management
    // Temporary: this per-frame polling mechanism will be replaced by
    // NSDKSession's Push Sessions with Combine publishers.

    func start(_ provider: ARProvider) {
        providers.append(provider)
        provider.start()
    }

    func stop(_ provider: ARProvider) {
        provider.stop()
        providers.removeAll { $0 === provider }
    }

    // MARK: - Data Source

    private func setupDataSource() {
        if let playbackSession = nsdkView.session as? PlaybackSession {
            dataSource = PlaybackSessionDataSource(session: playbackSession)
        } else {
            dataSource = DefaultSessionDataSource(
                session: nsdkView.session,
                orientationReporter: self
            )
        }
        nsdkSession.dataSource = dataSource
    }

    // MARK: - ARSession Lifecycle

    func startSession() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARUtils.isLidarAvailable() {
            config.frameSemantics.insert(.sceneDepth)
        }
        nsdkView.session.run(config)
        setupLighting()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stopSession() {
        nsdkView.session.pause()
    }

    private func setupLighting() {
        nsdkView.environment.lighting.intensityExponent = 1.0

        let light = DirectionalLight()
        light.light.intensity = 1000
        light.orientation = simd_quatf(
            angle: .pi / 4,
            axis: simd_normalize([1, 1, 0])
        )

        let lightAnchor = AnchorEntity(world: .zero)
        lightAnchor.addChild(light)
        nsdkView.scene.addAnchor(lightAnchor)
    }

    // MARK: - Per-Frame Update

    private func handleFrameUpdate() {
        nsdkSession.update()
        frameState.update(camera: nsdkView.getCamera())
        for provider in providers {
            provider.update()
        }
    }
}

// MARK: - NSDKViewDelegate

extension ARManager: NSDKViewDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        handleFrameUpdate()
    }

    func playbackSession(_ session: PlaybackSession, didUpdate frame: PlaybackFrame) {
        handleFrameUpdate()
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        frameState.update(trackingState: camera.trackingState)
    }

    func playbackSession(
        _ session: PlaybackSession,
        cameraDidChangeTrackingState camera: PlaybackCamera
    ) {
        frameState.update(trackingState: camera.trackingState)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let isEmpty = session.currentFrame?.anchors.isEmpty ?? true
        frameState.update(anchorsIsEmpty: isEmpty)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let isEmpty = session.currentFrame?.anchors.isEmpty ?? true
        frameState.update(anchorsIsEmpty: isEmpty)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        frameState.update(trackingState: .notAvailable)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARUtils.isLidarAvailable() {
            config.frameSemantics.insert(.sceneDepth)
        }
        nsdkView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        guard error is ARError else { return }
        let nsError = error as NSError
        let messages = [
            nsError.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion
        ]
        let message = messages.compactMap { $0 }.joined(separator: "\n")
        print("[ARManager] ARSession failed: \(message)")
    }
}
