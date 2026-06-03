// Copyright 2026 Niantic Spatial.

import SwiftUI

struct VPS2VCRepresentable: UIViewControllerRepresentable {
    let arManager: ARManager
    func makeUIViewController(context: Context) -> VPS2ViewController {
        VPS2ViewController(arManager: arManager)
    }
    func updateUIViewController(_ vc: VPS2ViewController, context: Context) {}
}
