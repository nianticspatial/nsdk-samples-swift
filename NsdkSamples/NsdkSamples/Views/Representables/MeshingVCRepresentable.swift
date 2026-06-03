// Copyright 2026 Niantic Spatial.

import SwiftUI

struct MeshingVCRepresentable: UIViewControllerRepresentable {
    let arManager: ARManager
    func makeUIViewController(context: Context) -> MeshingViewController {
        MeshingViewController(arManager: arManager)
    }
    func updateUIViewController(_ vc: MeshingViewController, context: Context) {}
}
