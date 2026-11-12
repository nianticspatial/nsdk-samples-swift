// Copyright 2026 Niantic Spatial.

import Combine
import CoreLocation
import NSDK
import SwiftUI

/// What a VPS2 localization run should target. Drives the `localize()` call and the
/// button label; the map pin is carried separately as `poiCoordinate`.
enum VPS2LocalizationTarget: Hashable {
    /// One VPS asset of a site, production or not.
    case site(id: String, assetId: String)
    case nearby(latitude: Double, longitude: Double, radiusMeters: Double)
}

/// A VPS asset the Switch Asset menu offers.
struct VPS2AssetChoice: Hashable {
    let id: String
    let name: String
    let deployment: AssetDeploymentType

    init(asset: AssetInfo) {
        id = asset.id
        name = asset.name
        deployment = asset.deployment
    }

    /// A plain String, so `Button` shows it verbatim rather than as a localization key.
    var menuTitle: String {
        "\(name) · \(deploymentLabel(deployment))"
    }
}

/// "Production" or "Not production": the portal has no other deployment state.
func deploymentLabel(_ deployment: AssetDeploymentType) -> String {
    deployment == .production ? "Production" : "Not production"
}

struct VPS2View: View {

    let arManager: ARManager
    let target: VPS2LocalizationTarget

    /// The target site's VPS assets, the one in `target` included. Empty for `.nearby`.
    let siteAssets: [VPS2AssetChoice]

    /// Map overlay POI pin. Cosmetic only, not the localization key.
    let poiCoordinate: CLLocationCoordinate2D?

    private let bottomChromeInset: CGFloat = 16
    private let maxButtonWidth: CGFloat = 200

    /// Areas whose RealityKit entities stay built, the shown one included.
    private let areaMeshCacheSize = 1

    // MARK: - State

    @State private var vps2Session: NSDKVps2Session?
    @State private var viewModel: VPS2ViewModel?
    @State private var sceneRenderer: VPS2SceneRenderer?
    @State private var retryHelper: AuthRetryHelper?
    @State private var debuggerCancellable: AnyCancellable?

    @State private var mapData = VPS2MapData()
    @State private var meshAssetId: String?
    @State private var infoText: String = ""
    @State private var showLocalizeButton: Bool = false
    @State private var isLocalizing = false
    /// The asset localize() asks for. Starts as the target's; Switch Asset changes it.
    @State private var targetAssetId: String?
    @State private var showBlurWarning: Bool = false
    @State private var siteFailureText: String?
    @State private var showDebuggerWebView = false
    @State private var debuggerSession: DebuggerSession?
    @State private var hasPlacedMarkers = false
    @State private var hasAnchors = false
    @State private var latestCamera: NSDKCamera?

    /// Result of the last long-press geotag, shown briefly above the map.
    @State private var geotagMessage: String?

    // MARK: - Body

    var body: some View {
        ZStack {
            NSDKViewRepresentable(arManager: arManager)
                .ignoresSafeArea()

            // Tap the AR camera view to drop a VPS anchor 1 m ahead (mirrors the Kotlin sample).
            // The chrome insets sit above this layer, so the map card and buttons take
            // their own taps.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    guard let camera = latestCamera else { return }
                    viewModel?.createAnchor(cameraTransform: camera.transform)
                }

                // Long-press to geotag the spot 2 m ahead with getGeolocation (mirrors the
                // Kotlin sample): it shows on the map and as a cube in AR.
                .onLongPressGesture {
                    guard let camera = latestCamera, let viewModel else { return }
                    if let geolocation = viewModel.geotagInFront(cameraTransform: camera.transform) {
                        showGeotagMessage(String(
                            format: "Geotagged %.6f, %.6f (heading %.0f°)",
                            geolocation.geolocationData.latitude,
                            geolocation.geolocationData.longitude,
                            geolocation.geolocationData.heading
                        ))
                    } else {
                        showGeotagMessage("Localize precisely (green) to geotag")
                    }
                }
                .ignoresSafeArea()

            // Feeds the view model's high-frequency asset and camera streams into the
            // RealityKit scene graph and the map overlay without re-evaluating the body.
            if let viewModel {
                Color.clear
                    .allowsHitTesting(false)
                    .onReceive(viewModel.$statusText) { text in
                        infoText = text
                    }
                    .onReceive(viewModel.$isImageTooBlurry) { blurry in
                        showBlurWarning = blurry
                    }
                    .onReceive(viewModel.$siteFailureText) { text in
                        siteFailureText = text
                    }
                    .onReceive(viewModel.$showMap) { show in
                        mapData.isVisible = show
                    }
                    .onReceive(viewModel.$userMapCoordinate) { coordinate in
                        mapData.userCoordinate = coordinate
                    }
                    .onReceive(viewModel.$userMapHeading) { heading in
                        mapData.userHeading = heading.map { Double($0) }
                    }
                    .onReceive(viewModel.$assetTrackingData) { tracking in
                        sceneRenderer?.updateAssetMarker(
                            transform: tracking?.assetToTrackingTransform)
                    }
                    .onReceive(arManager.frameState.$trackingState) { state in
                        sceneRenderer?.updateARTrackingState(state)
                    }
                    .onReceive(viewModel.$trackingState) { state in
                        mapData.isPlacementEnabled = (state == .precise)
                    }

                    // One array drives both the map dots and the AR cubes, so their
                    // colours cannot drift apart.
                    .onReceive(viewModel.$placedMarkers) { markers in
                        mapData.placedMarkers = markers
                        hasPlacedMarkers = !markers.isEmpty
                        sceneRenderer?.updatePlacedMarkers(markers)
                    }
                    .onReceive(viewModel.$guidanceTargetTransform) { transform in
                        sceneRenderer?.updateGuidanceTarget(transform: transform)
                    }
                    .onReceive(viewModel.$anchors) { anchors in
                        hasAnchors = !anchors.isEmpty
                        sceneRenderer?.updateAnchors(anchors)

                        // Plot each anchor's VPS2 geolocation on the mini-map (mirrors the Kotlin
                        // sample). Colours match the AR cubes: green when tracked, orange while
                        // limited. `.notTracked` anchors carry no coordinate, so they drop out.
                        mapData.anchorDots = anchors.compactMap { anchor in
                            guard let coordinate = anchor.coordinate else { return nil }
                            let color: Color = anchor.trackingState == .tracked ? .green : .orange
                            return VPS2AnchorMapDot(id: anchor.id, coordinate: coordinate, color: color)
                        }
                    }
                    .onReceive(arManager.frameState.$camera) { camera in
                        guard let camera else { return }
                        latestCamera = camera
                        sceneRenderer?.updateCamera(camera)
                    }
                    .onReceive(viewModel.$localizedAsset) { asset in
                        onLocalizedAssetChanged(asset)
                    }
            }

            // The insets below shrink this stack's safe area, so the panel fills only the
            // space the chrome leaves and cannot reach the buttons.
            //
            // Hiding fades the panel out rather than unmounting it. The viewer's dropdown is an
            // HTML <select>, and WebKit's native picker for it can still be animating away when
            // Hide is tapped; tearing the WebView down mid-animation segfaults on iOS 26.0-26.3.
            // Later 26.x releases fix it.
            if let debuggerSession {
                VpsDebuggerWebView(
                    bridge: debuggerSession.webBridge,
                    isVisible: showDebuggerWebView
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .opacity(showDebuggerWebView ? 1 : 0)
                .allowsHitTesting(showDebuggerWebView)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ARStatusView(frameState: arManager.frameState)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomChrome
        }
        .navigationTitle("VPS2 Localization")
        .onAppear { setup() }
        .onDisappear { teardown() }
    }

    /// Everything pinned to the bottom of the screen. Applied as a safe-area inset, so
    /// SwiftUI shrinks the content behind it by however tall it currently is.
    private var bottomChrome: some View {
        VStack(spacing: 0) {
            if showLocalizeButton {
                actionButton(localizeButtonTitle, color: .blue, action: localize)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            if isLocalizing {
                HStack(spacing: 10) {
                    actionButton("Stop Localizing", color: .red, action: stopLocalizing)
                    if !switchableAssets.isEmpty {
                        switchAssetMenu
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            if showBlurWarning {
                warningBanner("Image too blurry - hold the device steady", color: .orange)
            }

            if let siteFailureText {
                warningBanner(siteFailureText, color: .red)
            }

            if let geotagMessage {
                warningBanner(geotagMessage, color: .white)
            }

            // The debugger takes the map card's place rather than covering it.
            if !showDebuggerWebView {
                VPS2MapView(data: mapData, height: mapCardHeight) { coordinate in
                    viewModel?.placeMarker(at: coordinate)
                }
            }

            HStack(spacing: 10) {
                if hasPlacedMarkers || hasAnchors {
                    actionButton("Clear", color: .blue) { viewModel?.clearAll() }
                }

                actionButton(
                    showDebuggerWebView ? "Hide Debugger" : "Show Debugger",
                    color: .gray
                ) {
                    showDebuggerWebView.toggle()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            Text(infoText)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.55))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.bottom, bottomChromeInset)
        }
    }

    /// The map card is sized off the screen rather than the space left over in the
    /// chrome stack, so it does not resize when the Clear button or a warning banner
    /// appears alongside it.
    private var mapCardHeight: CGFloat {
        UIScreen.main.bounds.height / 3.0
    }

    /// Shares the width available in its row, capped at the screen's button width so a
    /// button never stretches wider than it did when the sizes were fixed.
    private func actionButton(
        _ title: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: maxButtonWidth)
                .frame(height: 44)
                .background(color)
                .cornerRadius(8)
        }
    }

    /// The target site's other VPS assets.
    private var switchableAssets: [VPS2AssetChoice] {
        siteAssets.filter { $0.id != targetAssetId }
    }

    private var switchAssetMenu: some View {
        Menu {
            ForEach(switchableAssets, id: \.id) { asset in
                Button(asset.menuTitle) {
                    switchAsset(to: asset.id)
                }
            }
        } label: {
            Text("Switch Asset")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: maxButtonWidth)
                .frame(height: 44)
                .background(Color.blue)
                .cornerRadius(8)
        }
    }

    /// Shows `message` for 3 s, unless a newer geotag replaces it first.
    private func showGeotagMessage(_ message: String) {
        geotagMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if geotagMessage == message { geotagMessage = nil }
        }
    }

    private func warningBanner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(color)
            .multilineTextAlignment(.center)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.55))
            .cornerRadius(10)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
    }

    private final class DebuggerSession {
        let eventBuffer: VpsDebuggerEventBuffer
        let webBridge: VpsDebuggerWebBridge

        init() {
            let buffer = VpsDebuggerEventBuffer()
            eventBuffer = buffer
            webBridge = VpsDebuggerWebBridge(eventBuffer: buffer)
        }
    }

    // MARK: - Actions

    private var localizeButtonTitle: String {
        switch target {
        case .site: return "Localize to Asset"
        case .nearby: return "Localize This Area"
        }
    }

    private func localize() {
        guard let retryHelper, let session = vps2Session else { return }
        infoText = "Localizing..."
        let assetId = targetAssetId ?? ""
        Task {
            do {
                try await retryHelper.withRetry {
                    switch target {
                    case .site(let id, _):
                        try session.localize(siteId: id, assetId: assetId)
                    case .nearby(let latitude, let longitude, let radiusMeters):
                        try session.localize(
                            latitude: latitude,
                            longitude: longitude,
                            radiusMeters: radiusMeters
                        )
                    }
                }
            } catch {
                print("Failed to localize. Error: \(String(describing: error))")
                // Nothing was requested, so offer Localize again rather than wait on it.
                infoText = "Failed to localize: \(error.localizedDescription)"
                isLocalizing = false
                showLocalizeButton = true
            }
        }
        showLocalizeButton = false
        isLocalizing = true
    }

    /// Stops localizing to the target and offers Localize again; the session keeps running.
    /// The SDK clears the localized asset, which drops its mesh in `onLocalizedAssetChanged`.
    private func stopLocalizing() {
        guard let session = vps2Session else { return }
        // A nearby request can target several sites; nil stops them all.
        let siteId: String?
        if case .site(let id, _) = target { siteId = id } else { siteId = nil }
        do {
            try session.stopLocalize(siteId: siteId)
        } catch {
            print("Failed to stop localizing. Error: \(String(describing: error))")
        }
        isLocalizing = false
        showLocalizeButton = true
        siteFailureText = nil
    }

    /// Moves to another VPS asset of the site. Localizing to a second asset of a site that is
    /// already a target would add it rather than replace the first, so the site is stopped first.
    private func switchAsset(to assetId: String) {
        stopLocalizing()
        targetAssetId = assetId
        localize()
    }

    /// Reacts to a newly localized asset or area. A new asset gets its display names resolved
    /// and its whole mesh downloaded once; every change shows the localized area's mesh. The red
    /// cube stays visible until the area's first mesh chunk arrives.
    private func onLocalizedAssetChanged(_ asset: Vps2LocalizedAsset?) {
        guard let viewModel, let retryHelper, let sceneRenderer else { return }

        // Stopping localization clears the asset. Drop its mesh, so it is not left floating and
        // localizing to the asset again downloads it again.
        guard let asset else {
            if meshAssetId != nil {
                meshAssetId = nil
                viewModel.cancelMeshDownload()
                viewModel.cancelNameLookup()
                sceneRenderer.resetAssetMesh(vpsMapAssetId: nil)
            }
            return
        }

        // The mesh only needs the ID, so neither of these waits on the other.
        if asset.assetId != meshAssetId {
            meshAssetId = asset.assetId
            viewModel.startNameLookup(
                for: asset,
                nsdkSession: arManager.nsdkSession,
                retryHelper: retryHelper
            )
            sceneRenderer.resetAssetMesh(vpsMapAssetId: asset.assetId)
            viewModel.startMeshDownload(
                vpsMapAssetId: asset.assetId,
                nsdkSession: arManager.nsdkSession,
                retryHelper: retryHelper
            ) { chunk in
                sceneRenderer.addAssetMeshChunk(chunk)
            }
        }

        // Chunks of a single-area asset carry an empty area id.
        sceneRenderer.showAssetMeshArea(asset.areaId ?? "")
    }

    // MARK: - Lifecycle

    private func setup() {
        guard viewModel == nil else { return }

        mapData.poiCoordinate = poiCoordinate

        let helper = AuthRetryHelper(session: arManager.nsdkSession)
        retryHelper = helper

        let session = arManager.nsdkSession.acquireVps2Session()
        vps2Session = session

        // Advisory blur check on, so too-blurry frames surface a "hold steady" warning.
        let debuggerSession = debuggerSession ?? DebuggerSession()
        self.debuggerSession = debuggerSession
        let eventBuffer = debuggerSession.eventBuffer
        let config = NSDKVps2Session.Configuration(
            initialVpsRequestsPerSecond: 1,
            continuousVpsRequestsPerSecond: 0.2,
            vpsDebuggerEnabled: true,
            blurDetectionEnabled: true,
            minSharpnessScore: 1000
        )
        do {
            try session.configure(with: config)
        } catch {
            print("[VPS2View] Failed to configure VPS2 session: \(error)")
        }

        let renderer = VPS2SceneRenderer(
            nsdkView: arManager.nsdkView,
            areaMeshCacheSize: areaMeshCacheSize
        )
        sceneRenderer = renderer

        let vm = VPS2ViewModel(session: session)
        viewModel = vm

        debuggerCancellable = session.debuggerEvents
            .sink { event in
                eventBuffer.add(event)
            }

        infoText = "Not localized."
        if case .site(_, let assetId) = target {
            targetAssetId = assetId
        }
        showLocalizeButton = true
        session.start()

        arManager.startSession()
    }

    private func teardown() {
        showDebuggerWebView = false
        debuggerCancellable?.cancel()
        debuggerCancellable = nil
        debuggerSession?.webBridge.hide()
        debuggerSession?.eventBuffer.clear()
        debuggerSession = nil
        viewModel?.releaseMeshDownloader(from: arManager.nsdkSession)
        viewModel?.cancelNameLookup()
        viewModel = nil
        meshAssetId = nil
        sceneRenderer?.clear()
        sceneRenderer = nil
        retryHelper = nil
        showLocalizeButton = false
        isLocalizing = false
        try? vps2Session?.stopLocalize()
        vps2Session?.stop()
        arManager.stopSession()
        if let vps2Session {
            arManager.nsdkSession.destroy(vps2Session)
        }
        vps2Session = nil
    }
}
