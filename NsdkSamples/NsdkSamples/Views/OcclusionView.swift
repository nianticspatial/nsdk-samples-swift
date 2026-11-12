// Copyright 2026 Niantic Spatial.

import SwiftUI
import NSDK
import Combine

struct OcclusionView: View {

    let arManager: ARManager

    // MARK: - State

    @State private var cubeDistance: Float = 2.0
    @State private var isHelpVisible = false
    @State private var depthSession: NSDKDepthSession?
    @State private var viewModel: OcclusionViewModel?

    // MARK: - Constants

    private static let cubeDistanceMin: Float = 1.0
    private static let cubeDistanceMax: Float = 5.0

    private static let helpText =
        "Occlusion Sample Help\n\n This sample uses NSDK depth to hide a virtual cube behind real geometry." +
        "\n\n TO USE: use the slider to adjust the distance of the cube from the camera."

    // MARK: - Body

    var body: some View {
        ZStack {
            // Bottom layer: AR camera feed (full screen)
            NSDKViewRepresentable(arManager: arManager)
                .ignoresSafeArea()

            // Middle layer: occlusion rendering (full screen)
            if let viewModel {
                OcclusionMTKViewRepresentable(
                    arManager: arManager,
                    viewModel: viewModel,
                    cubeDistance: cubeDistance
                )
                .ignoresSafeArea()
            }

            // Top layer: SwiftUI controls
            VStack {
                ARStatusView(frameState: arManager.frameState)

                HelpOverlayView(
                    helpText: Self.helpText,
                    isVisible: $isHelpVisible
                )

                Spacer()

                // Bottom controls
                VStack(spacing: 0) {
                    // Cube distance label
                    Text(String(format: "Cube: %.1f m", cubeDistance))
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .padding(.bottom, 5)

                    // Cube distance slider
                    Slider(value: $cubeDistance, in: Self.cubeDistanceMin...Self.cubeDistanceMax)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 30)
                }
            }
        }
        .navigationTitle("Occlusion")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Help") {
                    isHelpVisible.toggle()
                }
            }
        }
        .onAppear {
            guard depthSession == nil else { return }

            let session = arManager.nsdkSession.acquireDepthSession()
            do {
                try session.configure(with: NSDKDepthSession.Configuration())
            } catch {
                print("[OcclusionView] Failed to configure depth session: \(error)")
            }

            viewModel = OcclusionViewModel(depthSession: session)
            depthSession = session

            session.start()
            arManager.startSession()
        }
        .onDisappear {
            depthSession?.stop()
            arManager.stopSession()
            if let session = depthSession {
                arManager.nsdkSession.destroy(session)
            }
        }
    }
}
