// Copyright 2026 Niantic Spatial.

import SwiftUI

struct CaptureVCRepresentable: UIViewControllerRepresentable {
    let arManager: ARManager
    func makeUIViewController(context: Context) -> CaptureViewController {
        CaptureViewController(arManager: arManager)
    }
    func updateUIViewController(_ vc: CaptureViewController, context: Context) {}
}
