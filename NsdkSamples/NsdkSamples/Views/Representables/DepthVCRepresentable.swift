// Copyright 2026 Niantic Spatial.

import SwiftUI

struct DepthVCRepresentable: UIViewControllerRepresentable {
    let arManager: ARManager
    func makeUIViewController(context: Context) -> DepthViewController {
        DepthViewController(arManager: arManager)
    }
    func updateUIViewController(_ vc: DepthViewController, context: Context) {}
}
