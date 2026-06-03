// Copyright 2026 Niantic Spatial.

import SwiftUI

struct DeviceMappingVCRepresentable: UIViewControllerRepresentable {
    let arManager: ARManager
    func makeUIViewController(context: Context) -> DeviceMappingViewController {
        DeviceMappingViewController(arManager: arManager)
    }
    func updateUIViewController(_ vc: DeviceMappingViewController, context: Context) {}
}
