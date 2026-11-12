// Copyright 2026 Niantic Spatial.

import SwiftUI
import NSDK
import Combine

struct MainView: View {

    // MARK: - Menu items

    fileprivate enum MenuItemID: Int, CaseIterable, Identifiable, Hashable {
        case sites = 0
        case depth
        case occlusion
        case sceneSegmentation
        case capture
        case deviceMapping
        case meshing

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .sites: return "VPS2 (with Sites)"
            case .depth: return "Depth"
            case .occlusion: return "Occlusion"
            case .sceneSegmentation: return "Scene Segmentation"
            case .capture: return "Capture"
            case .deviceMapping: return "Device Mapping"
            case .meshing: return "Meshing"
            }
        }

        @ViewBuilder
        func destination(arManager: ARManager) -> some View {
            switch self {
            case .sites: SitesView(arManager: arManager)
            case .depth: DepthView(arManager: arManager)
            case .occlusion: OcclusionView(arManager: arManager)
            case .sceneSegmentation: SceneSegmentationView(arManager: arManager)
            case .deviceMapping: DeviceMappingView(arManager: arManager)
            case .capture: CaptureView(arManager: arManager)
            case .meshing: MeshingView(arManager: arManager)
            }
        }
    }

    // MARK: - State

    @State private var authState: AuthView.AuthState = .loggedOut
    @State private var showAuthSheet = false
    @State private var hasAutoPromptedLogin = false
    @State private var navigationPath = NavigationPath()

    /// Opens the sample the user tapped while downloads ran, once they confirm.
    @State private var pendingSampleOpen: (() -> Void)?
    @StateObject private var playbackLibrary = PlaybackLibrary()

    private let loginManager = LoginManager()

    // MARK: - Body

    var body: some View {
        // The banner sits above the stack, so each screen's navigation bar starts below it.
        VStack(spacing: 0) {
            playbackBanner
            navigationStack
        }
    }

    private var navigationStack: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                versionLabel
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 20) {
                        ForEach(MenuItemID.allCases) { item in
                            menuButton(item.title) {
                                openSample { navigationPath.append(item) }
                            }
                        }
                        menuButton("Playback Select") {
                            guard navigationPath.isEmpty else { return }
                            navigationPath.append(PlaybackSelectRoute())
                        }

                        // Samples contributed at runtime via SampleRegistry (empty by default).
                        ForEach(SampleRegistry.shared.entries) { entry in
                            menuButton(entry.title) {
                                openSample { navigationPath.append(entry) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
            }
            .background(Color.white)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MenuItemID.self) { item in
                ARSessionView(playbackDataset: playbackLibrary.activeDataset) {
                    AnyView(item.destination(arManager: $0))
                }
            }
            .navigationDestination(for: SampleEntry.self) { entry in
                ARSessionView(playbackDataset: playbackLibrary.activeDataset) { entry.makeDestination($0) }
            }
            .navigationDestination(for: PlaybackSelectRoute.self) { _ in
                PlaybackSelectView(library: playbackLibrary)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    authButton
                }
            }
            .alert(cancelDownloadsTitle, isPresented: isConfirmingSampleOpen) {
                Button("Open", role: .destructive) {
                    if let open = pendingSampleOpen { startSample(open) }
                    pendingSampleOpen = nil
                }
                Button("Cancel", role: .cancel) { pendingSampleOpen = nil }
            }
            .sheet(isPresented: $showAuthSheet) {
                AuthView(
                    authState: authState,
                    loginManager: loginManager,
                    onLogin: {
                        showAuthSheet = false
                        loginManager.startAuth()
                    },
                    onLogout: {
                        NSSampleSessionManager.stopNSSampleSession()
                        showAuthSheet = false
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .onReceive(NotificationCenter.default.publisher(for: nsSampleSessionDidSetNotification)) { _ in
                refreshAuthState()
            }
            .onReceive(NotificationCenter.default.publisher(for: nsSampleSessionDidStopNotification)) { _ in
                authState = .loggedOut
            }
            .onAppear {
                NSSampleSessionManager.start()
                refreshAuthState()
                promptLoginIfNeeded()
            }
        }
    }

    // MARK: - Sample opening

    private var isConfirmingSampleOpen: Binding<Bool> {
        Binding(get: { pendingSampleOpen != nil }, set: { if !$0 { pendingSampleOpen = nil } })
    }

    private var cancelDownloadsTitle: String {
        PlaybackLibrary.cancelDownloadsPrompt(
            count: playbackLibrary.downloadingCount, question: "Open the sample anyway?")
    }

    /// Opens a sample with `open`, first asking to cancel any downloads still running.
    private func openSample(_ open: @escaping () -> Void) {
        guard navigationPath.isEmpty else { return }
        if playbackLibrary.downloadingCount > 0 {
            pendingSampleOpen = open
        } else {
            startSample(open)
        }
    }

    private func startSample(_ open: () -> Void) {
        // Each sample creates its own NSDKSession, so the library releases its session first;
        // NSDK-9090 tracks sharing one session across the samples.
        playbackLibrary.releaseForSample()
        open()
    }

    // MARK: - Playback banner

    /// Names the scan playing in place of the camera, with a stop button that returns to the live
    /// camera on the menu and Playback Select only.
    @ViewBuilder
    private var playbackBanner: some View {
        if let scan = playbackLibrary.activeScan {
            let showsStop = navigationPath.isEmpty || playbackLibrary.isSelecting
            HStack {
                Text("▶ Playback: \(scan.displayName)")
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                if showsStop {
                    Button { playbackLibrary.useLiveCamera() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                    }
                    .accessibilityLabel("Stop playback")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.ignoresSafeArea(edges: .top))
        }
    }

    // MARK: - Menu button

    @ViewBuilder
    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
                .background(Color.blue)
                .cornerRadius(8)
        }
    }

    // MARK: - Version label

    private var versionLabel: some View {
        let text = NSDKSession.version()
        let display = text.isEmpty ? "NSDK" : "NSDK v\(text)"
        return Text(display)
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Auth button

    @ViewBuilder
    private var authButton: some View {
        switch authState {
        case .loggedOut:
            Button { showAuthSheet = true } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.gray)
            }
        case .loggingIn:
            ProgressView()
        case .loggedIn, .loggedInWithToken:
            Button { showAuthSheet = true } label: {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.green)
            }
        }
    }

    // MARK: - Auth state

    private func refreshAuthState() {
        if AuthUtils.isValidJwt(AuthConstants.accessToken) {
            authState = .loggedInWithToken
        } else if NSSampleSessionManager.isSessionInProgress {
            let email = AuthUtils.jwtEmail(for: NSSampleSessionManager.sampleToken)
            authState = .loggedIn(email: email)
        } else {
            authState = .loggedOut
        }
    }

    private func promptLoginIfNeeded() {
        guard !hasAutoPromptedLogin else { return }
        hasAutoPromptedLogin = true
        guard nsdkNeedsAuth() else { return }
        showAuthSheet = true
    }

    private func nsdkNeedsAuth() -> Bool {
        if !AuthUtils.isTokenEmptyOrExpiring(AuthConstants.accessToken, minUnexpiredTimeLeft: 0) {
            return false
        }
        return !NSSampleSessionManager.isSessionInProgress
    }
}

/// Navigation value for Playback Select.
private struct PlaybackSelectRoute: Hashable {}

// MARK: - AR Session Host & View
//
// `ARSessionHost` owns the `NSDKSession` and its `ARManager` for the lifetime of a
// navigation destination: it builds them on creation and tears the session down in
// `deinit`. Holding it via `@StateObject` keeps a single instance across view updates
// and releases it only when the destination is removed from the navigation stack.

private final class ARSessionHost: ObservableObject {
    let arManager: ARManager
    private var authSubscription: AnyCancellable?

    init(playbackDataset: PlaybackDataset?) {
        let session = NSDKSession(
            accessToken: AuthConstants.accessToken,
            // Playback requests LiDAR depth only when the dataset recorded it; live follows the device.
            useLidar: playbackDataset?.hasDepth() ?? ARUtils.isLidarAvailable()
        )
        authSubscription = NSSampleSessionManager.setupSessionAccess(for: session)
        arManager = ARManager(nsdkSession: session, playbackDataset: playbackDataset)
    }

    deinit {
        // teardown() touches UIKit/ARKit, so it must run on the main thread. When this deinit
        // already runs there, which is the normal SwiftUI case, tear down inline. Deferring with
        // DispatchQueue.main.async would keep `arManager`, and so the owned NSDKSession, alive
        // past this deinit. If the next scene constructs its session before that block runs,
        // NSDKSession's single-active-session guard fatalerrors.
        let manager = arManager
        if Thread.isMainThread {
            MainActor.assumeIsolated { manager.teardown() }
        } else {
            DispatchQueue.main.async { manager.teardown() }
        }
    }
}

private struct ARSessionView: View {
    /// Builds the sample's screen from the host-owned `ARManager`. Both the built-in menu items and
    /// registry-contributed samples route through here so every destination gets a managed session.
    let makeContent: (ARManager) -> AnyView
    @StateObject private var host: ARSessionHost

    init(playbackDataset: PlaybackDataset?, makeContent: @escaping (ARManager) -> AnyView) {
        self.makeContent = makeContent
        _host = StateObject(wrappedValue: ARSessionHost(playbackDataset: playbackDataset))
    }

    var body: some View {
        makeContent(host.arManager)
    }
}
