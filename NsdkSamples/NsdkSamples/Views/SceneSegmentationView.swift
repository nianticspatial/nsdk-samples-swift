// Copyright 2026 Niantic Spatial.

import SwiftUI
import NSDK
import Combine
import ARKit

struct SceneSegmentationView: View {

    let arManager: ARManager

    // MARK: - State

    @State private var transparency: Float = 0.5
    @State private var isOverlayVisible = true
    @State private var selectedChannelIndex: Int = {
        let channels = SceneSegmentationChannels.allChannels
        return channels.firstIndex(where: { $0 == .ground }) ?? 0
    }()
    @State private var isChannelPickerVisible = false
    @State private var isHelpVisible = false
    @State private var sceneSegmentationSession: NSDKSceneSegmentationSession?
    @State private var viewModel: SceneSegmentationViewModel?

    // MARK: - Constants

    private let channels = SceneSegmentationChannels.allChannels

    private static let helpText =
        "Scene Segmentation Sample Help\n\n" +
        "This sample uses our scene segmentation feature and a shader to represent it, " +
        "coloring pink where a channel is detected and blue where it is not.\n\n" +
        "TO USE:\n" +
        "Select a semantic channel from the drop-down menu, and use the transparency " +
        "slider to see the color highlight overlaid on the camera feed."

    // MARK: - Body

    var body: some View {
        ZStack {
            // Bottom layer: AR camera feed (full screen)
            NSDKViewRepresentable(arManager: arManager)
                .ignoresSafeArea()

            // Middle layer: segmentation overlay (full screen)
            if let viewModel {
                TextureViewRepresentable(
                    viewModel: viewModel,
                    vertexShader: "semanticVertexShader",
                    fragmentShader: "semanticFragmentShader",
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
                    // Channel picker
                    if isChannelPickerVisible {
                        Picker("Channel", selection: $selectedChannelIndex) {
                            ForEach(0..<channels.count, id: \.self) { index in
                                Text(formatChannelName(channels[index]))
                                    .foregroundColor(.white)
                                    .tag(index)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 120)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(8)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 5)
                        .transition(.opacity)
                    }

                    // Channel button
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isChannelPickerVisible.toggle()
                        }
                    } label: {
                        let arrow = isChannelPickerVisible ? "▲" : "▼"
                        let name = formatChannelName(channels[selectedChannelIndex])
                        Text("Semantic Channel: \(name) \(arrow)")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.blue)
                            .cornerRadius(8)
                            .opacity(isChannelPickerVisible ? 0.7 : 1.0)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

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
        .navigationTitle("Scene Segmentation")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Help") {
                    isHelpVisible.toggle()
                }
            }
        }
        .onChange(of: selectedChannelIndex) { _, newValue in
            sceneSegmentationSession?.confidenceChannel = channels[newValue]
        }
        .onAppear {
            guard sceneSegmentationSession == nil else { return }

            let session = arManager.nsdkSession.acquireSceneSegmentationSession()
            do {
                try session.configure(with: NSDKSceneSegmentationSession.Configuration())
            } catch {
                print("[SceneSegmentationView] Failed to configure session: \(error)")
            }

            session.confidenceChannel = channels[selectedChannelIndex]
            viewModel = SceneSegmentationViewModel(
                sceneSegmentationSession: session,
                frameState: arManager.frameState
            )
            sceneSegmentationSession = session

            session.start()
            arManager.startSession()
        }
        .onDisappear {
            sceneSegmentationSession?.stop()
            arManager.stopSession()
            if let session = sceneSegmentationSession {
                arManager.nsdkSession.destroy(session)
            }
        }
    }

    // MARK: - Helpers

    private func formatChannelName(_ channel: SceneSegmentationChannels) -> String {
        channel.channelDebugName
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
