// Copyright 2026 Niantic Spatial.

import SwiftUI
import NSDK
import Combine

struct MainView: View {

    // MARK: - Menu items

    fileprivate enum MenuItemID: Int, CaseIterable, Identifiable, Hashable {
        case sites = 0
        case vps2
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
            case .vps2: return "VPS2 (with anchor payload)"
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
            case .sites: SitesVCRepresentable(arManager: arManager).ignoresSafeArea()
            case .vps2: VPS2VCRepresentable(arManager: arManager).ignoresSafeArea()
            case .depth: DepthVCRepresentable(arManager: arManager).ignoresSafeArea()
            case .occlusion: OcclusionVCRepresentable(arManager: arManager).ignoresSafeArea()
            case .sceneSegmentation: SceneSegmentationView(arManager: arManager)
            case .capture: CaptureVCRepresentable(arManager: arManager).ignoresSafeArea()
            case .deviceMapping: DeviceMappingVCRepresentable(arManager: arManager).ignoresSafeArea()
            case .meshing: MeshingVCRepresentable(arManager: arManager).ignoresSafeArea()
            }
        }
    }

    // MARK: - State

    @State private var authState: AuthView.AuthState = .loggedOut
    @State private var showAuthSheet = false
    @State private var hasAutoPromptedLogin = false
    @State private var authSubscription: AnyCancellable?
    @State private var navigationPath = NavigationPath()
    @State private var isNavigating = false

    private let loginManager = LoginManager()

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                versionLabel
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 20) {
                        ForEach(MenuItemID.allCases) { item in
                            Button {
                                guard !isNavigating else { return }
                                isNavigating = true
                                navigationPath.append(item)
                            } label: {
                                Text(item.title)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 20)
                                    .background(Color.blue)
                                    .cornerRadius(8)
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
                ARSessionView(item: item, authSubscriptionBinding: $authSubscription)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    authButton
                }
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
                isNavigating = false
                authSubscription = nil
                NSSampleSessionManager.start()
                refreshAuthState()
                promptLoginIfNeeded()
            }
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

// MARK: - AR Session View (defers ARManager creation to navigation time)

private struct ARSessionView: View {
    let item: MainView.MenuItemID  // fileprivate access
    @Binding var authSubscriptionBinding: AnyCancellable?
    @State private var arManager: ARManager?

    var body: some View {
        Group {
            if let arManager {
                item.destination(arManager: arManager)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard arManager == nil else { return }
            let session = NSDKSession(
                accessToken: AuthConstants.accessToken,
                useLidar: ARUtils.isLidarAvailable()
            )
            authSubscriptionBinding = NSSampleSessionManager.setupSessionAccess(for: session)
            arManager = ARManager(nsdkSession: session)
        }
    }
}
