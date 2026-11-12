// Copyright 2026 Niantic Spatial.

import SwiftUI
import NSDK
import Combine

struct MeshingView: View {

    let arManager: ARManager

    // MARK: - Session, ViewModel & Mesh Store

    @State private var meshingSession: NSDKMeshingSession?
    @State private var viewModel: MeshingViewModel?
    @State private var meshChunkStore: MeshChunkEntityStore?

    // MARK: - UI State

    @State private var isMeshing = false
    @State private var infoText = "Ready to begin Meshing"
    @State private var isHelpVisible = false

    // MARK: - Help

    private static let helpText =
        "Meshing Sample Help\n\n" +
        "This sample creates a 3D mesh of the environment in front of your device camera.\n\n" +
        "TO USE:\n" +
        "Press the \"Start Meshing\" button and move the camera around. A mesh is dynamically " +
        "created and rendered. The mesh is not persistent — to restart, press \"Stop Meshing\" " +
        "and the process will restart."

    // MARK: - Body

    var body: some View {
        ZStack {
            NSDKViewRepresentable(arManager: arManager)
                .ignoresSafeArea()

            // Subscribe to the ViewModel. Color.clear is just a transparent, non-interactive
            // host for the onReceive modifier (viewModel is optional, so we gate with `if let`)
            // — it must not obscure or block the views below.
            if let viewModel {
                Color.clear
                    .allowsHitTesting(false)
                    // Render each batch of mesh chunk changes and refresh the chunk count.
                    .onReceive(viewModel.updatedMeshChunks) { changes in
                        meshChunkStore?.apply(changes)
                        infoText = "Total mesh chunks: \(meshChunkStore?.chunkCount ?? 0)"
                    }
            }

            VStack(spacing: 0) {
                ARStatusView(frameState: arManager.frameState)

                HelpOverlayView(helpText: Self.helpText, isVisible: $isHelpVisible)

                Spacer()

                Text(infoText)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 5)

                Button(isMeshing ? "Stop Meshing" : "Start Meshing") {
                    if isMeshing { stopMeshing() } else { startMeshing() }
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 180, height: 44)
                .background(Color.blue)
                .cornerRadius(8)
                .padding(.bottom, 20)
            }
        }
        .navigationTitle("Meshing")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Help") {
                    isHelpVisible.toggle()
                }
            }
        }
        .onAppear { setup() }
        .onDisappear { teardown() }
    }

    // MARK: - Lifecycle

    private func setup() {
        guard viewModel == nil else { return }

        let session = arManager.nsdkSession.acquireMeshingSession()
        meshingSession = session
        viewModel = MeshingViewModel(meshingSession: session)
        meshChunkStore = MeshChunkEntityStore(nsdkView: arManager.nsdkView)

        arManager.startSession()
    }

    private func teardown() {
        stopMeshing()
        arManager.stopSession()
        meshChunkStore?.clear()
        meshChunkStore?.detach()
        viewModel?.cleanup()
        meshingSession = nil
        viewModel = nil
        meshChunkStore = nil
    }

    // MARK: - Meshing Control

    private func startMeshing() {
        isMeshing = true

        var config = NSDKMeshingSession.Configuration()
        config.fuseKeyframesOnly = true

        do {
            meshChunkStore?.clear()
            try meshingSession?.configure(with: config)
            meshingSession?.start()
        } catch {
            print("[MeshingView] Unable to start meshing: \(error)")
        }

        infoText = "Meshing Started"
    }

    private func stopMeshing() {
        isMeshing = false
        meshingSession?.stop()
        infoText = "Meshing Stopped"
    }
}
