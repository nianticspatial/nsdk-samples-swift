// Copyright 2026 Niantic Spatial.

import SwiftUI

struct OcclusionVCRepresentable: UIViewControllerRepresentable {
    let arManager: ARManager
    func makeUIViewController(context: Context) -> OcclusionViewController {
        OcclusionViewController(arManager: arManager)
    }
    func updateUIViewController(_ vc: OcclusionViewController, context: Context) {}
}
