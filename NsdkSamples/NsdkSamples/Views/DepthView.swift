// Copyright 2026 Niantic Spatial.

import SwiftUI
import NSDK
import Combine

struct DepthView: View {

    let arManager: ARManager

    // MARK: - State

    @State private var transparency: Float = 1.0
    @State private var isOverlayVisible = true
    @State private var isHelpVisible = false
    @State private var depthSession: NSDKDepthSession?
    @State private var viewModel: DepthViewModel?

    // MARK: - Constants

    private static let helpText =
        "Depth Sample Help\n\n" +
        "This sample displays a representation of the depth in a color scale from blue, " +
        "for closest objects, to red, for the farthest.\n\n" +
        "TO USE:\n" +
        "The display starts automatically. Use the transparency slider to blend the depth " +
        "view with the camera feed, or press the \"Hide\" button to fully hide it and see " +
        "the unchanged camera feed."

    // MARK: - Body

    var body: some View {
        ZStack {
            // Bottom layer: AR camera feed (full screen)
            NSDKViewRepresentable(arManager: arManager)
                .ignoresSafeArea()

            // Middle layer: depth overlay (full screen)
            if let viewModel {
                TextureViewRepresentable(
                    viewModel: viewModel,
                    vertexShader: "depthVertexShader",
                    fragmentShader: "depthFragmentShader",
                    opacity: transparency,
                    isVisible: isOverlayVisible
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
                    // Slider label
                    Text("Transparency: \(Int(transparency * 100))%")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .padding(.bottom, 5)

                    // Transparency slider
                    Slider(value: $transparency, in: 0...1)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)

                    // Toggle button
                    HStack {
                        Spacer()
                        Button {
                            isOverlayVisible.toggle()
                        } label: {
                            Text(isOverlayVisible ? "Hide" : "Show")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 180, height: 44)
                                .background(Color.blue)
                                .cornerRadius(8)
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
        .navigationTitle("Depth")
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
                print("[DepthView] Failed to configure depth session: \(error)")
            }

            viewModel = DepthViewModel(depthSession: session, frameState: arManager.frameState)
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
