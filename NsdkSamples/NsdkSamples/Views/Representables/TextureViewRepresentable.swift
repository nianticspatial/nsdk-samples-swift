// Copyright 2026 Niantic Spatial.

import SwiftUI
import Metal
import Combine

struct TextureViewRepresentable: UIViewRepresentable {
    let viewModel: SceneSegmentationViewModel
    let vertexShader: String
    let fragmentShader: String
    var opacity: Float
    var isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> TextureView {
        let view = TextureView(
            frame: .zero,
            vertexShader: vertexShader,
            fragmentShader: fragmentShader
        )
        view.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.opacity = opacity

        context.coordinator.subscribe(to: viewModel, textureView: view)

        return view
    }

    func updateUIView(_ uiView: TextureView, context: Context) {
        let wasHidden = uiView.isHidden
        let shouldHide = !isVisible

        if wasHidden && !shouldHide {
            uiView.reset()
        }

        uiView.opacity = opacity
        uiView.isHidden = shouldHide
    }

    // MARK: - Coordinator

    class Coordinator {
        var cancellables = Set<AnyCancellable>()

        func subscribe(to viewModel: SceneSegmentationViewModel, textureView: TextureView) {
            viewModel.$segmentationTexture
                .receive(on: DispatchQueue.main)
                .sink { [weak textureView] texture in
                    guard let textureView, let texture else { return }
                    textureView.setTexture(copyFrom: texture)
                }
                .store(in: &cancellables)

            viewModel.$reprojection
                .receive(on: DispatchQueue.main)
                .sink { [weak textureView] matrix in
                    textureView?.setReprojection(matrix)
                }
                .store(in: &cancellables)
        }
    }
}
