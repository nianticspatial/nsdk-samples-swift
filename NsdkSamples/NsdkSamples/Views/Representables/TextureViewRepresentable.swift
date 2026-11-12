// Copyright 2026 Niantic Spatial.

import SwiftUI
import Metal
import Combine
import simd

protocol TextureProviding: AnyObject {
    var texturePublisher: Published<MTLTexture?>.Publisher { get }
    var reprojectionPublisher: Published<matrix_float3x3>.Publisher? { get }
}

extension TextureProviding {
    var reprojectionPublisher: Published<matrix_float3x3>.Publisher? { nil }
}

struct TextureViewRepresentable: UIViewRepresentable {
    let viewModel: any TextureProviding
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

        func subscribe(to viewModel: any TextureProviding, textureView: TextureView) {
            viewModel.texturePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak textureView] texture in
                    guard let textureView, let texture else { return }
                    textureView.setTexture(copyFrom: texture)
                }
                .store(in: &cancellables)

            if let reprojectionPublisher = viewModel.reprojectionPublisher {
                reprojectionPublisher
                    .receive(on: DispatchQueue.main)
                    .sink { [weak textureView] matrix in
                        textureView?.setReprojection(matrix)
                    }
                    .store(in: &cancellables)
            }
        }
    }
}
